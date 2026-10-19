//! Nook voor Windows, Linux en Android. De kern zit in `nook-core`; hier zitten de vensters, het systeemvak,
//! de sneltoetsen, de commando's voor de interface en de platformlaag.

mod brain;
mod commands;
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

    builder
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            if let Ok(dir) = app.path().app_data_dir() {
                nook_core::paths::set_support_directory(dir);
            }
            app.manage(state::AppState::new(platform::secrets::system_store()));
            brain::setup(app.handle());
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
            commands::brain::memory_overview,
            commands::brain::memory_add,
            commands::brain::memory_edit,
            commands::brain::memory_delete,
            commands::brain::memory_set_pinned,
            commands::brain::memory_set_local_only,
            commands::brain::memory_clear,
            commands::brain::memory_import,
            commands::brain::brain_advice,
            commands::brain::pull_model,
            commands::brain::use_local_model,
            commands::brain::brain_test,
            commands::brain::brain_eval,
            commands::brain::mail_update,
            commands::brain::mail_send,
            commands::brain::mail_open,
            commands::brain::read_attachment,
            commands::brain::source_choices,
            commands::brain::set_scope,
            commands::brain::start_suggestions,
            commands::brain::retry_last,
            commands::brain::plan_edit,
            commands::brain::plan_include,
            commands::brain::plan_run_again,
        ])
        .run(tauri::generate_context!())
        .expect("Nook kon niet starten");
}
