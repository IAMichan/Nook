//! Nook voor Windows, Linux en Android. De kern zit in `nook-core`; hier zitten de vensters, het systeemvak,
//! de sneltoetsen, de commando's voor de interface en de platformlaag.

mod commands;
mod companion;
mod connectors;
mod platform;
mod state;
mod tools;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    #[cfg(desktop)]
    {
        // Eén Nook tegelijk: een tweede start haalt het venster van de eerste naar voren.
        builder = builder
            .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
                platform::desktop::show_main(app, platform::desktop::route_from_args(&args).unwrap_or("chat"))
            }))
            .plugin(tauri_plugin_global_shortcut::Builder::new().build());
    }

    #[cfg(mobile)]
    {
        builder = builder.plugin(tauri_plugin_barcode_scanner::init()).plugin(tauri_plugin_notification::init());
    }

    builder
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            if let Ok(dir) = app.path().app_data_dir() {
                nook_core::paths::set_support_directory(dir);
            }
            app.manage(state::AppState::new(platform::secrets::system_store()));
            companion::setup(app.handle());
            connectors::setup(app.handle());
            #[cfg(desktop)]
            {
                platform::desktop::setup(app.handle())?;
                // `nook --window` (bv. vanuit het startmenu) opent meteen het hoofdvenster.
                let args: Vec<String> = std::env::args().collect();
                if let Some(route) = platform::desktop::route_from_args(&args) {
                    platform::desktop::show_main(app.handle(), route);
                }
            }
            #[cfg(mobile)]
            if let Some(main) = app.get_webview_window("main") {
                let _ = main.show();
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Het hoofdvenster sluiten verbergt het; Nook blijft in de balk en het systeemvak.
            #[cfg(desktop)]
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
            #[cfg(not(desktop))]
            let _ = (window, event);
        })
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            commands::get_settings,
            commands::save_settings,
            commands::providers,
            commands::list_models,
            commands::key_status,
            commands::set_key,
            commands::nooks_list,
            commands::nooks_search,
            commands::nook_get,
            commands::nook_active,
            commands::nook_new,
            commands::nook_delete,
            commands::nook_set_flags,
            commands::ask,
            commands::stop,
            commands::plan_steps,
            commands::execute_plan,
            commands::cancel_plan,
            commands::open_loops,
            commands::complete_loop,
            commands::audit_entries,
            commands::clear_audit,
            commands::bar_expand,
            commands::show_main,
            commands::bar_moved,
            commands::take_route,
            commands::companion::companion_info,
            commands::companion::companion_set_enabled,
            commands::companion::companion_begin_pairing,
            commands::companion::companion_cancel_pairing,
            commands::companion::companion_remove_device,
            commands::companion::companion_set_push,
            commands::companion::companion_set_apns,
            commands::companion::companion_remove_apns_key,
            commands::companion::companion_push_test,
            commands::companion::companion_client,
            commands::companion::companion_client_pair,
            commands::companion::companion_client_unpair,
            commands::companion::companion_client_refresh,
            commands::companion::companion_client_decide,
            commands::companion::companion_client_answer,
            commands::companion::companion_client_send,
            commands::companion::companion_client_stop,
            commands::companion::companion_client_clear_notice,
            commands::companion::companion_client_visible,
            commands::connectors::connectors_overview,
            commands::connectors::connector_save,
            commands::connectors::connector_disconnect,
            commands::connectors::connector_toggle,
            commands::connectors::connector_refresh,
            commands::connectors::account_add,
            commands::connectors::account_rename,
            commands::connectors::account_remove,
            commands::connectors::account_token,
            commands::connectors::github_cli,
            commands::connectors::github_device_start,
            commands::connectors::github_pull_requests,
            commands::connectors::mcp_paste,
            commands::connectors::mcp_add,
            commands::connectors::mcp_remove,
            commands::connectors::mcp_set_enabled,
            commands::connectors::mcp_test,
            commands::connectors::mcp_connect_service,
            commands::connectors::mcp_sign_in,
            commands::connectors::gitlab_save,
            commands::connectors::gitlab_remove,
            commands::connectors::whatsapp_view,
            commands::connectors::whatsapp_save,
            commands::connectors::whatsapp_credential,
            commands::connectors::whatsapp_test,
            commands::connectors::whatsapp_chats,
            commands::connectors::whatsapp_reply,
            commands::connectors::whatsapp_mark_read,
            commands::connectors::whatsapp_ignore,
            commands::connectors::whatsapp_unmute,
            commands::connectors::chat_accounts,
            commands::connectors::chat_accounts_set,
            commands::connectors::service_icon,
        ])
        .build(tauri::generate_context!())
        .expect("Nook kon niet starten")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                connectors::shutdown(app);
            }
        });
}
