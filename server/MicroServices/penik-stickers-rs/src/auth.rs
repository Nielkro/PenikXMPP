use axum::{
    async_trait,
    extract::FromRequestParts,
    http::{request::Parts, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("Missing Authorization header")]
    MissingHeader,
    #[error("Invalid Authorization scheme (must be Bearer)")]
    InvalidScheme,
    #[error("Invalid token format")]
    InvalidFormat,
    #[error("Token expired")]
    Expired,
    #[error("Invalid signature")]
    InvalidSignature,
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let status = match self {
            AuthError::MissingHeader | AuthError::InvalidScheme => StatusCode::UNAUTHORIZED,
            AuthError::Expired => StatusCode::UNAUTHORIZED,
            AuthError::InvalidFormat | AuthError::InvalidSignature => StatusCode::FORBIDDEN,
        };
        let body = Json(crate::models::ApiResponse::<()>::err(self.to_string()));
        (status, body).into_response()
    }
}

pub fn generate_token(jid: &str, expires_at: i64, shared_secret: &str) -> String {
    let payload = format!("{}:{}", jid, expires_at);
    let mut mac = HmacSha256::new_from_slice(shared_secret.as_bytes())
        .expect("HMAC can take key of any size");
    mac.update(payload.as_bytes());
    let sig = hex::encode(mac.finalize().into_bytes());
    let raw = format!("{}:{}:{}", jid, expires_at, sig);
    BASE64.encode(raw.as_bytes())
}

pub fn verify_token(token: &str, shared_secret: &str) -> Result<String, AuthError> {
    let decoded = BASE64
        .decode(token.trim().as_bytes())
        .map_err(|_| AuthError::InvalidFormat)?;
    let decoded_str = String::from_utf8(decoded).map_err(|_| AuthError::InvalidFormat)?;

    let parts: Vec<&str> = decoded_str.split(':').collect();
    if parts.len() < 3 {
        return Err(AuthError::InvalidFormat);
    }

    let sig = parts[parts.len() - 1];
    let expires_at_str = parts[parts.len() - 2];
    let jid = parts[..parts.len() - 2].join(":"); // Support JIDs containing colons if any

    let expires_at: i64 = expires_at_str.parse().map_err(|_| AuthError::InvalidFormat)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    if expires_at <= now {
        return Err(AuthError::Expired);
    }

    let payload = format!("{}:{}", jid, expires_at);
    let mut mac = HmacSha256::new_from_slice(shared_secret.as_bytes())
        .map_err(|_| AuthError::InvalidSignature)?;
    mac.update(payload.as_bytes());

    let expected_sig = hex::encode(mac.finalize().into_bytes());
    if sig != expected_sig {
        return Err(AuthError::InvalidSignature);
    }

    Ok(jid)
}

#[derive(Debug, Clone)]
pub struct AuthUser(pub String);

#[async_trait]
impl<S> FromRequestParts<S> for AuthUser
where
    S: Send + Sync,
{
    type Rejection = AuthError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .ok_or(AuthError::MissingHeader)?
            .to_str()
            .map_err(|_| AuthError::InvalidScheme)?;

        if !auth_header.starts_with("Bearer ") {
            return Err(AuthError::InvalidScheme);
        }

        let token = &auth_header["Bearer ".len()..];
        let shared_secret = parts
            .extensions
            .get::<std::sync::Arc<crate::config::Config>>()
            .map(|c| c.shared_secret.as_str())
            .unwrap_or("penik_secret_shared_key");

        let jid = verify_token(token, shared_secret)?;
        Ok(AuthUser(jid))
    }
}

#[derive(Debug, Clone)]
pub struct MaybeAuthUser(pub Option<String>);

#[async_trait]
impl<S> FromRequestParts<S> for MaybeAuthUser
where
    S: Send + Sync,
{
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok());

        if let Some(auth_header) = auth_header {
            if auth_header.starts_with("Bearer ") {
                let token = &auth_header["Bearer ".len()..];
                let shared_secret = parts
                    .extensions
                    .get::<std::sync::Arc<crate::config::Config>>()
                    .map(|c| c.shared_secret.as_str())
                    .unwrap_or("penik_secret_shared_key");

                if let Ok(jid) = verify_token(token, shared_secret) {
                    return Ok(MaybeAuthUser(Some(jid)));
                }
            }
        }

        Ok(MaybeAuthUser(None))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_token_generate_and_verify() {
        let secret = "super_secret_key_123";
        let jid = "alice@snikket.penik.ru";
        let expires = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
            + 3600;

        let token = generate_token(jid, expires, secret);
        let verified = verify_token(&token, secret).expect("verification should succeed");
        assert_eq!(verified, jid);
    }

    #[test]
    fn test_expired_token() {
        let secret = "super_secret_key_123";
        let jid = "bob@snikket.penik.ru";
        let expires = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
            - 10;

        let token = generate_token(jid, expires, secret);
        let err = verify_token(&token, secret).unwrap_err();
        match err {
            AuthError::Expired => {}
            _ => panic!("Expected Expired error, got {:?}", err),
        }
    }

    #[test]
    fn test_tampered_token() {
        let secret = "super_secret_key_123";
        let jid = "charlie@snikket.penik.ru";
        let expires = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
            + 3600;

        let token = generate_token(jid, expires, secret);
        let err = verify_token(&token, "wrong_secret").unwrap_err();
        match err {
            AuthError::InvalidSignature => {}
            _ => panic!("Expected InvalidSignature error, got {:?}", err),
        }
    }
}
