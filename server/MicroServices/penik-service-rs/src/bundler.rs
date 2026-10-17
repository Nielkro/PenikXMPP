use crate::models::{PackWithStickers, Sticker, StickerPack};
use std::{fs::File, io::Write, path::Path};
use zip::{write::SimpleFileOptions, ZipWriter};

pub fn build_pack_bundle(
    pack_dir: &Path,
    bundle_path: &Path,
    pack: &StickerPack,
    stickers: &[Sticker],
) -> anyhow::Result<()> {
    let tmp_bundle_path = bundle_path.with_extension("tmp");
    let file = File::create(&tmp_bundle_path)?;
    let mut zip = ZipWriter::new(file);

    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);

    // 1. Add pack.json
    let pack_with_stickers = PackWithStickers {
        pack: pack.clone(),
        stickers: stickers.to_vec(),
        installed: false,
    };
    let json_bytes = serde_json::to_vec_pretty(&pack_with_stickers)?;
    zip.start_file("pack.json", options)?;
    zip.write_all(&json_bytes)?;

    // 2. Add each sticker file and its thumbnail
    for s in stickers {
        let sticker_path = pack_dir.join(&s.file_name);
        if sticker_path.is_file() {
            let data = std::fs::read(&sticker_path)?;
            zip.start_file(&s.file_name, options)?;
            zip.write_all(&data)?;
        }

        let thumb_name = format!("thumb_{}.webp", s.id);
        let thumb_path = pack_dir.join(&thumb_name);
        if thumb_path.is_file() {
            let thumb_data = std::fs::read(&thumb_path)?;
            zip.start_file(&thumb_name, options)?;
            zip.write_all(&thumb_data)?;
        }
    }

    zip.finish()?;

    // Atomically rename tmp to final bundle.zip
    std::fs::rename(&tmp_bundle_path, bundle_path)?;

    Ok(())
}
