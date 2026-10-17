use std::path::Path;
use tokio::process::Command;
use tracing::{error, info};

pub async fn transcode_webm_to_animated_webp(
    input_path: &Path,
    output_path: &Path,
) -> anyhow::Result<()> {
    info!(
        "Transcoding WebM to Animated WebP: {} -> {}",
        input_path.display(),
        output_path.display()
    );

    let status = Command::new("ffmpeg")
        .args([
            "-y",
            "-c:v",
            "libvpx-vp9",
            "-i",
        ])
        .arg(input_path)
        .args([
            "-vcodec",
            "libwebp",
            "-filter:v",
            "fps=20,scale=256:256:flags=lanczos",
            "-lossless",
            "0",
            "-compression_level",
            "6",
            "-q:v",
            "65",
            "-loop",
            "0",
        ])
        .arg(output_path)
        .status()
        .await?;

    if !status.success() {
        error!("FFmpeg transcoding failed with status: {:?}", status);
        anyhow::bail!("FFmpeg transcoding failed with status: {:?}", status);
    }

    Ok(())
}

pub async fn generate_webm_thumbnail(
    input_path: &Path,
    thumb_path: &Path,
) -> anyhow::Result<()> {
    let status = Command::new("ffmpeg")
        .args([
            "-y",
            "-c:v",
            "libvpx-vp9",
            "-i",
        ])
        .arg(input_path)
        .args([
            "-vframes",
            "1",
            "-vcodec",
            "libwebp",
            "-filter:v",
            "scale=128:128:flags=lanczos",
            "-lossless",
            "0",
            "-compression_level",
            "6",
            "-q:v",
            "70",
        ])
        .arg(thumb_path)
        .status()
        .await?;

    if !status.success() {
        error!("FFmpeg webm thumbnail generation failed with status: {:?}", status);
        anyhow::bail!("FFmpeg webm thumbnail failed with status: {:?}", status);
    }

    Ok(())
}

pub async fn generate_webp_thumbnail(
    input_path: &Path,
    thumb_path: &Path,
) -> anyhow::Result<()> {
    let status = Command::new("ffmpeg")
        .args([
            "-y",
            "-i",
        ])
        .arg(input_path)
        .args([
            "-vframes",
            "1",
            "-vcodec",
            "libwebp",
            "-filter:v",
            "scale=128:128:flags=lanczos",
            "-lossless",
            "0",
            "-compression_level",
            "6",
            "-q:v",
            "70",
        ])
        .arg(thumb_path)
        .status()
        .await?;

    if !status.success() {
        error!("FFmpeg webp thumbnail generation failed with status: {:?}", status);
        anyhow::bail!("FFmpeg webp thumbnail failed with status: {:?}", status);
    }

    Ok(())
}
