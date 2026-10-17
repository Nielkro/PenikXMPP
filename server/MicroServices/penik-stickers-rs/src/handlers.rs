use crate::{
    auth::{AuthUser, MaybeAuthUser},
    bundler::build_pack_bundle,
    config::Config,
    db,
    models::{ApiResponse, ImportRequest, PackWithStickers, Sticker, StickerPack},
    telegram::TelegramClient,
    transcode::{
        generate_webm_thumbnail, generate_webp_thumbnail, transcode_webm_to_animated_webp,
    },
};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use sqlx::SqlitePool;
use std::{path::PathBuf, sync::Arc};
use tracing::{error, info};

pub struct AppState {
    pub pool: SqlitePool,
    pub config: Arc<Config>,
    pub tg_client: TelegramClient,
}

pub async fn get_my_packs(
    AuthUser(user_jid): AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ApiResponse<Vec<StickerPack>>>, (StatusCode, Json<ApiResponse<()>>)> {
    match db::get_user_installed_packs(&state.pool, &user_jid).await {
        Ok(packs) => Ok(Json(ApiResponse::success(packs))),
        Err(e) => {
            error!("Failed to fetch user packs for {}: {:?}", user_jid, e);
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiResponse::err(e.to_string())),
            ))
        }
    }
}

pub async fn get_pack(
    Path(pack_id): Path<String>,
    MaybeAuthUser(user_jid): MaybeAuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ApiResponse<PackWithStickers>>, (StatusCode, Json<ApiResponse<()>>)> {
    let pack = match db::get_pack_by_id(&state.pool, &pack_id).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiResponse::err("Pack not found")),
            ))
        }
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiResponse::err(e.to_string())),
            ))
        }
    };

    let stickers = db::get_stickers_by_pack_id(&state.pool, &pack_id)
        .await
        .unwrap_or_default();

    let installed = if let Some(jid) = user_jid {
        db::is_pack_installed(&state.pool, &jid, &pack_id)
            .await
            .unwrap_or(false)
    } else {
        false
    };

    Ok(Json(ApiResponse::success(PackWithStickers {
        pack,
        stickers,
        installed,
    })))
}

pub async fn install_pack(
    Path(pack_id): Path<String>,
    AuthUser(user_jid): AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ApiResponse<()>>, (StatusCode, Json<ApiResponse<()>>)> {
    match db::get_pack_by_id(&state.pool, &pack_id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiResponse::err("Pack not found")),
            ))
        }
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiResponse::err(e.to_string())),
            ))
        }
    }

    match db::install_pack(&state.pool, &user_jid, &pack_id).await {
        Ok(_) => Ok(Json(ApiResponse::success(()))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiResponse::err(e.to_string())),
        )),
    }
}

pub async fn uninstall_pack(
    Path(pack_id): Path<String>,
    AuthUser(user_jid): AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ApiResponse<()>>, (StatusCode, Json<ApiResponse<()>>)> {
    match db::uninstall_pack(&state.pool, &user_jid, &pack_id).await {
        Ok(_) => Ok(Json(ApiResponse::success(()))),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiResponse::err(e.to_string())),
        )),
    }
}

pub async fn import_telegram_pack(
    AuthUser(user_jid): AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<ImportRequest>,
) -> Result<Json<ApiResponse<PackWithStickers>>, (StatusCode, Json<ApiResponse<()>>)> {
    // 1. Sanitize pack name: remove URL prefixes if user pasted full t.me link
    let raw_name = req.name.trim();
    let tg_name = if let Some(idx) = raw_name.rfind('/') {
        &raw_name[idx + 1..]
    } else {
        raw_name
    };

    if tg_name.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiResponse::err("Invalid Telegram pack name")),
        ));
    }

    // 2. Check if already imported
    if let Ok(Some(existing_pack)) = db::get_pack_by_tg_name(&state.pool, tg_name).await {
        let _ = db::install_pack(&state.pool, &user_jid, &existing_pack.id).await;
        let stickers = db::get_stickers_by_pack_id(&state.pool, &existing_pack.id)
            .await
            .unwrap_or_default();
        return Ok(Json(ApiResponse::success(PackWithStickers {
            pack: existing_pack,
            stickers,
            installed: true,
        })));
    }

    // 3. Fetch Telegram sticker set info
    info!("Importing sticker set from Telegram: {}", tg_name);
    let tg_set = state.tg_client.get_sticker_set(tg_name).await.map_err(|e| {
        error!("Telegram getStickerSet failed: {:?}", e);
        (
            StatusCode::BAD_GATEWAY,
            Json(ApiResponse::err(format!("Telegram API error: {}", e))),
        )
    })?;

    let has_video = tg_set.is_video
        || tg_set.sticker_format.as_deref() == Some("video")
        || tg_set.stickers.iter().any(|s| s.is_video);
    let has_animated = tg_set.is_animated
        || tg_set.sticker_format.as_deref() == Some("animated")
        || tg_set.stickers.iter().any(|s| s.is_animated);

    let format_str = if has_video {
        "animated_webp"
    } else if has_animated {
        "animated"
    } else {
        "static"
    };

    let pack_id = format!("tg_{}", tg_name.to_lowercase());
    let pack_dir = PathBuf::from(&state.config.storage_dir).join(&pack_id);
    tokio::fs::create_dir_all(&pack_dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiResponse::err(e.to_string())),
        )
    })?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    let mut stickers = Vec::new();
    let mut cover_sticker_id = String::new();

    for (idx, s) in tg_set.stickers.iter().enumerate() {
        let sticker_id = format!("stk_{}", s.file_unique_id);
        if idx == 0 {
            cover_sticker_id = sticker_id.clone();
        }

        let file_path = match state.tg_client.get_file_path(&s.file_id).await {
            Ok(p) => p,
            Err(e) => {
                error!("Failed to get file path for sticker {}: {:?}", s.file_id, e);
                continue;
            }
        };

        let file_bytes = match state.tg_client.download_file(&file_path).await {
            Ok(b) => b,
            Err(e) => {
                error!("Failed to download sticker {}: {:?}", s.file_id, e);
                continue;
            }
        };

        let is_video = s.is_video
            || tg_set.is_video
            || tg_set.sticker_format.as_deref() == Some("video")
            || file_bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]);

        let is_animated = s.is_animated
            || tg_set.is_animated
            || tg_set.sticker_format.as_deref() == Some("animated")
            || file_bytes.starts_with(&[0x1F, 0x8B]);

        let final_file_name = if is_video {
            let tmp_webm = pack_dir.join(format!("{}_raw.webm", sticker_id));
            let out_webp = pack_dir.join(format!("{}.webp", sticker_id));
            let thumb_webp = pack_dir.join(format!("thumb_{}.webp", sticker_id));

            if let Err(e) = tokio::fs::write(&tmp_webm, &file_bytes).await {
                error!("Failed to write tmp webm: {:?}", e);
                continue;
            }

            if let Err(e) = transcode_webm_to_animated_webp(&tmp_webm, &out_webp).await {
                error!("Failed to transcode webm sticker: {:?}", e);
                let _ = tokio::fs::remove_file(&tmp_webm).await;
                continue;
            }

            let _ = generate_webm_thumbnail(&tmp_webm, &thumb_webp).await;
            let _ = tokio::fs::remove_file(&tmp_webm).await;
            format!("{}.webp", sticker_id)
        } else if is_animated {
            let out_tgs = pack_dir.join(format!("{}.tgs", sticker_id));
            let thumb_webp = pack_dir.join(format!("thumb_{}.webp", sticker_id));

            if let Err(e) = tokio::fs::write(&out_tgs, &file_bytes).await {
                error!("Failed to write tgs file: {:?}", e);
                continue;
            }

            // Download thumbnail if telegram provided it
            if let Some(ref thumb) = s.thumbnail {
                if let Ok(thumb_path) = state.tg_client.get_file_path(&thumb.file_id).await {
                    if let Ok(thumb_bytes) = state.tg_client.download_file(&thumb_path).await {
                        let _ = tokio::fs::write(&thumb_webp, &thumb_bytes).await;
                    }
                }
            }
            format!("{}.tgs", sticker_id)
        } else {
            let out_webp = pack_dir.join(format!("{}.webp", sticker_id));
            let thumb_webp = pack_dir.join(format!("thumb_{}.webp", sticker_id));

            if let Err(e) = tokio::fs::write(&out_webp, &file_bytes).await {
                error!("Failed to write static webp: {:?}", e);
                continue;
            }

            let _ = generate_webp_thumbnail(&out_webp, &thumb_webp).await;
            format!("{}.webp", sticker_id)
        };

        stickers.push(Sticker {
            id: sticker_id,
            pack_id: pack_id.clone(),
            emoji: s.emoji.clone().unwrap_or_default(),
            file_name: final_file_name,
            width: s.width,
            height: s.height,
            sort_order: idx as i32,
        });
    }

    if stickers.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiResponse::err("Failed to process any stickers in the pack")),
        ));
    }

    let pack = StickerPack {
        id: pack_id.clone(),
        telegram_name: Some(tg_name.to_string()),
        title: tg_set.title,
        author_jid: user_jid.clone(),
        cover_sticker_id,
        format: format_str.to_string(),
        created_at: now,
    };

    // 4. Build single pre-assembled bundle.zip
    let bundle_path = pack_dir.join("bundle.zip");
    if let Err(e) = build_pack_bundle(&pack_dir, &bundle_path, &pack, &stickers) {
        error!("Failed to build bundle.zip: {:?}", e);
    }

    // 5. Save to database
    db::save_pack_and_stickers(&state.pool, &pack, &stickers)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiResponse::err(e.to_string())),
            )
        })?;

    // 6. Automatically install for importing user
    let _ = db::install_pack(&state.pool, &user_jid, &pack.id).await;

    Ok(Json(ApiResponse::success(PackWithStickers {
        pack,
        stickers,
        installed: true,
    })))
}

pub async fn get_bundle_zip(
    Path(pack_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Response {
    let bundle_path = PathBuf::from(&state.config.storage_dir)
        .join(&pack_id)
        .join("bundle.zip");

    if !bundle_path.is_file() {
        return (StatusCode::NOT_FOUND, "Bundle not found").into_response();
    }

    match tokio::fs::read(&bundle_path).await {
        Ok(data) => {
            let mut headers = HeaderMap::new();
            headers.insert(header::CONTENT_TYPE, "application/zip".parse().unwrap());
            headers.insert(
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{}_bundle.zip\"", pack_id)
                    .parse()
                    .unwrap(),
            );
            headers.insert(
                header::CACHE_CONTROL,
                "public, max-age=86400".parse().unwrap(),
            );
            (StatusCode::OK, headers, Body::from(data)).into_response()
        }
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Failed to read bundle").into_response(),
    }
}

pub async fn get_file(
    Path((pack_id, file_name)): Path<(String, String)>,
    State(state): State<Arc<AppState>>,
) -> Response {
    // Prevent directory traversal
    if file_name.contains("..") || file_name.contains('/') || file_name.contains('\\') {
        return (StatusCode::BAD_REQUEST, "Invalid file name").into_response();
    }

    let file_path = PathBuf::from(&state.config.storage_dir)
        .join(&pack_id)
        .join(&file_name);

    if !file_path.is_file() {
        return (StatusCode::NOT_FOUND, "File not found").into_response();
    }

    let mime = if file_name.ends_with(".webp") {
        "image/webp"
    } else if file_name.ends_with(".tgs") {
        "application/x-tgsticker"
    } else if file_name.ends_with(".json") {
        "application/json"
    } else {
        "application/octet-stream"
    };

    match tokio::fs::read(&file_path).await {
        Ok(data) => {
            let mut headers = HeaderMap::new();
            headers.insert(header::CONTENT_TYPE, mime.parse().unwrap());
            headers.insert(
                header::CACHE_CONTROL,
                "public, max-age=604800, immutable".parse().unwrap(),
            );
            (StatusCode::OK, headers, Body::from(data)).into_response()
        }
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Failed to read file").into_response(),
    }
}
