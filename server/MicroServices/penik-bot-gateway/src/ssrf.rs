use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use std::net::{IpAddr, SocketAddr};

/// SSRF-safe DNS resolver implementing reqwest's Resolve trait.
/// Strictly blocks loopback, private RFC1918, link-local, and unique-local IPv6 ranges.
/// By resolving within reqwest, it also prevents DNS rebinding (TOCTOU) attacks.
#[derive(Debug, Clone, Default)]
pub struct SafeDnsResolver;

impl Resolve for SafeDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        Box::pin(async move {
            let host_str = name.as_str();
            // Default to port 443 if not specified
            let addrs = tokio::net::lookup_host((host_str, 443)).await?;

            let safe_addrs: Vec<SocketAddr> = addrs
                .filter(|addr| is_public_routable(&addr.ip()))
                .collect();

            if safe_addrs.is_empty() {
                return Err(Box::new(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    format!("Destination host '{}' resolved exclusively to private or loopback IP (blocked by SSRF filter)", host_str),
                )) as Box<dyn std::error::Error + Send + Sync>);
            }

            let boxed: Addrs = Box::new(safe_addrs.into_iter());
            Ok(boxed)
        })
    }
}

/// Helper to verify whether an IP is globally routable and public
pub fn is_public_routable(ip: &IpAddr) -> bool {
    if ip.is_loopback() || ip.is_unspecified() {
        return false;
    }
    match ip {
        IpAddr::V4(ipv4) => {
            let octets = ipv4.octets();
            // 127.0.0.0/8 (loopback) - already covered by is_loopback()
            // 10.0.0.0/8 (private)
            if octets[0] == 10 {
                return false;
            }
            // 172.16.0.0/12 (private)
            if octets[0] == 172 && (16..=31).contains(&octets[1]) {
                return false;
            }
            // 192.168.0.0/16 (private)
            if octets[0] == 192 && octets[1] == 168 {
                return false;
            }
            // 169.254.0.0/16 (link-local)
            if octets[0] == 169 && octets[1] == 254 {
                return false;
            }
            // 100.64.0.0/10 (carrier-grade NAT)
            if octets[0] == 100 && (64..=127).contains(&octets[1]) {
                return false;
            }
            // 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 (documentation)
            if (octets[0] == 192 && octets[1] == 0 && octets[2] == 2)
                || (octets[0] == 198 && octets[1] == 51 && octets[2] == 100)
                || (octets[0] == 203 && octets[1] == 0 && octets[2] == 113)
            {
                return false;
            }
            // 224.0.0.0/4 (multicast)
            if octets[0] >= 224 {
                return false;
            }
            // 255.255.255.255 (broadcast)
            if ipv4.is_broadcast() {
                return false;
            }
            true
        }
        IpAddr::V6(ipv6) => {
            let segments = ipv6.segments();
            // ::1 (loopback) - covered by is_loopback()
            // fc00::/7 (unique local address)
            if (segments[0] & 0xfe00) == 0xfc00 {
                return false;
            }
            // fe80::/10 (link-local unicast)
            if (segments[0] & 0xffc0) == 0xfe80 {
                return false;
            }
            // ff00::/8 (multicast)
            if (segments[0] & 0xff00) == 0xff00 {
                return false;
            }
            // ::ffff:0:0/96 (IPv4-mapped IPv6)
            if segments[0] == 0
                && segments[1] == 0
                && segments[2] == 0
                && segments[3] == 0
                && segments[4] == 0
                && segments[5] == 0xffff
            {
                let v4 = IpAddr::V4(std::net::Ipv4Addr::new(
                    (segments[6] >> 8) as u8,
                    segments[6] as u8,
                    (segments[7] >> 8) as u8,
                    segments[7] as u8,
                ));
                return is_public_routable(&v4);
            }
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_ssrf_blocking_private_and_loopback() {
        let blocked = [
            "127.0.0.1",
            "127.0.1.1",
            "10.0.0.1",
            "10.254.1.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.0.1",
            "192.168.1.100",
            "169.254.169.254", // Cloud metadata
            "100.64.0.1",      // Carrier-grade NAT
            "0.0.0.0",
            "255.255.255.255",
            "::1",
            "fe80::1",
            "fc00::1",
            "::ffff:127.0.0.1", // IPv4-mapped IPv6
            "::ffff:192.168.1.1",
        ];

        for ip_str in blocked {
            let ip = IpAddr::from_str(ip_str).unwrap();
            assert!(!is_public_routable(&ip), "Expected IP {} to be blocked", ip_str);
        }
    }

    #[test]
    fn test_ssrf_allowing_public_ips() {
        let allowed = [
            "8.8.8.8",
            "1.1.1.1",
            "140.82.121.4",
            "2001:4860:4860::8888",
        ];

        for ip_str in allowed {
            let ip = IpAddr::from_str(ip_str).unwrap();
            assert!(is_public_routable(&ip), "Expected public IP {} to be allowed", ip_str);
        }
    }
}

