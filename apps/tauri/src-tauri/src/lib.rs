//! Nook voor Windows, Linux en Android. De kern zit in `nook-core`; hier zitten de vensters, het systeemvak,
//! de sneltoetsen, de commando's voor de interface en de platformlaag.

mod agents;
pub mod cli;
mod commands;
mod platform;
mod state;
mod tools;
mod workspace;

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
            .plugin(tauri_plugin_global_shortcut::Builder::new().build())
            .plugin(tauri_plugin_dialog::init());
    }

    builder
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            if let Ok(dir) = app.path().app_data_dir() {
                nook_core::paths::set_support_directory(dir);
            }
            app.manage(state::AppState::new(platform::secrets::system_store()));
            agents::setup(app.handle());
            workspace::setup(app.handle());
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
            commands::agents::agents_overview,
            commands::agents::agents_decide,
            commands::agents::agents_decide_in_terminal,
            commands::agents::agents_answer,
            commands::agents::agents_answer_in_terminal,
            commands::agents::agents_end,
            commands::agents::agents_forget,
            commands::agents::agents_can_end,
            commands::agents::agents_transcript,
            commands::agents::agents_history,
            commands::agents::agents_integrations,
            commands::agents::agents_prepare_link,
            commands::agents::agents_apply_link,
            commands::agents::agents_discard_link,
            commands::agents::agents_profiles,
            commands::agents::agents_profile_add,
            commands::agents::agents_profile_rename,
            commands::agents::agents_profile_remove,
            commands::agents::agents_profile_prefer,
            commands::agents::agents_profile_auth,
            commands::agents::agents_profile_key,
            commands::agents::agents_mark_finished,
            commands::agents::agents_visit,
            commands::agents::agents_activate_terminal,
            commands::agents::agents_run_in_terminal,
            commands::agents::agents_terminal_name,
            commands::agents::agents_sound,
            commands::workspace::workspace_overview,
            commands::workspace::workspace_save_settings,
            commands::workspace::workspace_forget_project,
            commands::workspace::workspace_timeline,
            commands::workspace::workspace_queue,
            commands::workspace::workspace_inspect,
            commands::workspace::workspace_start,
            commands::workspace::workspace_adopt,
            commands::workspace::workspace_configure,
            commands::workspace::workspace_send,
            commands::workspace::workspace_steer,
            commands::workspace::workspace_enqueue,
            commands::workspace::workspace_queue_remove,
            commands::workspace::workspace_queue_move,
            commands::workspace::workspace_queue_edit,
            commands::workspace::workspace_queue_send_now,
            commands::workspace::workspace_queue_steer,
            commands::workspace::workspace_stop,
            commands::workspace::workspace_retry,
            commands::workspace::workspace_rename,
            commands::workspace::workspace_set_auto_resume,
            commands::workspace::workspace_archive,
            commands::workspace::workspace_mark_reviewed,
            commands::workspace::workspace_delete,
            commands::workspace::workspace_usage,
            commands::workspace::workspace_git,
            commands::workspace::workspace_diff,
            commands::workspace::workspace_commit,
            commands::workspace::workspace_push,
            commands::workspace::workspace_can_revert,
            commands::workspace::workspace_revert,
            commands::workspace::workspace_worktrees,
            commands::workspace::workspace_remove_worktree,
            commands::workspace::workspace_continue_live,
            commands::workspace::workspace_quick,
            commands::workspace::workspace_clone,
            commands::workspace::workspace_pull,
            commands::workspace::workspace_commit_all,
            commands::workspace::workspace_pull_request_draft,
            commands::workspace::workspace_create_pull_request,
            commands::workspace::workspace_continue_past,
            commands::workspace_tools::terminal_list,
            commands::workspace_tools::terminal_open,
            commands::workspace_tools::terminal_write,
            commands::workspace_tools::terminal_resize,
            commands::workspace_tools::terminal_replay,
            commands::workspace_tools::terminal_interrupt,
            commands::workspace_tools::terminal_close,
            commands::workspace_tools::workspace_folder_tools,
            commands::workspace_tools::browser_state,
            commands::workspace_tools::workspace_link_bridge,
            commands::workspace_tools::browser_go,
            commands::workspace_tools::browser_step,
            commands::workspace_tools::browser_read,
            commands::workspace_tools::browser_close,
        ])
        .build(tauri::generate_context!())
        .expect("Nook kon niet starten")
        .run(|app, event| {
            // Bij afsluiten: lopende agents van de werkruimte netjes stoppen.
            if let tauri::RunEvent::Exit = event {
                workspace::shutdown(app);
            }
        });
}
