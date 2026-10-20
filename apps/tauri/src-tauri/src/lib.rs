//! Nook voor Windows, Linux en Android. De kern zit in `nook-core`; hier zitten de vensters, het systeemvak,
//! de sneltoetsen, de commando's voor de interface en de platformlaag.

mod agents;
mod brain;
pub mod cli;
mod commands;
mod companion;
mod connectors;
mod platform;
mod services;
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

    #[cfg(mobile)]
    {
        builder = builder.plugin(tauri_plugin_barcode_scanner::init());
    }

    builder
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            if let Ok(dir) = app.path().app_data_dir() {
                nook_core::paths::set_support_directory(dir);
            }
            app.manage(state::AppState::new(platform::secrets::system_store()));
            companion::setup(app.handle());
            connectors::setup(app.handle());
            services::setup(app.handle());
            brain::setup(app.handle());
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
            commands::services::services_prefs,
            commands::services::save_services_prefs,
            commands::services::voice_info,
            commands::services::now_playing,
            commands::services::media_command,
            commands::services::media_seek,
            commands::services::media_shuffle,
            commands::services::media_repeat,
            commands::services::media_volume,
            commands::services::voice_start,
            commands::services::voice_finish,
            commands::services::voice_cancel,
            commands::services::voice_follow,
            commands::services::speak_text,
            commands::services::speak_stop,
            commands::services::flow_view,
            commands::services::save_flow_settings,
            commands::services::save_flow_dictionary,
            commands::services::flow_clear_history,
            commands::services::flow_cancel,
            commands::services::flow_hands_free,
            commands::services::notes_list,
            commands::services::note_markdown,
            commands::services::note_delete,
            commands::services::note_toggle,
            commands::services::note_live,
            commands::services::look_along,
            commands::services::nudge_current,
            commands::services::nudge_answer,
            commands::services::aside_expand,
            commands::services::aside_hide,
            commands::services::aside_show,
            commands::services::screen_status,
            commands::services::screen_part_begin,
            commands::services::screen_part_image,
            commands::services::screen_part_finish,
            commands::services::screen_part_cancel,
            commands::services::today_items,
            commands::services::recap_view,
            commands::services::sound_file,
            commands::services::open_sounds_folder,
            commands::autocomplete::autocomplete_view,
            commands::autocomplete::autocomplete_pause,
            commands::autocomplete::autocomplete_resume,
            commands::autocomplete::autocomplete_reset_stats,
            commands::autocomplete::autocomplete_models,
            commands::autocomplete::autocomplete_playground,
            commands::autocomplete::autocomplete_playground_cancel,
            commands::autocomplete::autocomplete_emoji,
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
            if let tauri::RunEvent::Exit = event {
                // Bij afsluiten: de WhatsApp-gateway en lopende agents van de werkruimte netjes stoppen.
                connectors::shutdown(app);
                workspace::shutdown(app);
            }
        });
}
