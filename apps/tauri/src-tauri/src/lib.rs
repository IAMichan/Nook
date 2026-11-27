//! Nook voor Windows, Linux en Android. De kern zit in `nook-core`; hier zitten de vensters, het systeemvak,
//! de sneltoetsen, de commando's voor de interface en de platformlaag.

mod agents;
mod brain;
mod chats;
pub mod cli;
mod commands;
mod companion;
mod connectors;
mod diagnostics;
mod games;
mod keybindings;
mod notice_history;
mod notices;
mod permissions;
mod person_notes;
mod platform;
mod services;
mod state;
mod storage;
mod tools;
mod update_runner;
mod updates;
mod workspace;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    diagnostics::start();
    let mut builder = tauri::Builder::default();

    #[cfg(desktop)]
    {
        // Eén Nook tegelijk: een tweede start haalt het venster van de eerste naar voren.
        builder = builder
            .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
                // The task that keeps Nook running starts it every minute; while it runs, that start ends quietly.
                if args.iter().any(|a| a == companion::background::BACKGROUND_ARG) {
                    return;
                }
                // A click on a toast after Nook restarted (Windows starts `nook.exe "nook://notice?…"`).
                if let Some(link) = nook_core::services::toast::ToastLink::from_args(&args) {
                    return notices::respond(app, link, None);
                }
                platform::desktop::show_main(app, platform::desktop::route_from_args(&args).unwrap_or("chat"))
            }))
            .plugin(tauri_plugin_global_shortcut::Builder::new().build())
            // Starten bij het inloggen: de aan/uit-knop staat in Instellingen > Algemeen.
            .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--login"])))
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
            // A new build that crashed before it proved healthy is rolled back here, before the database opens.
            update_runner::at_launch();
            app.manage(state::AppState::new(platform::secrets::system_store()));
            app.manage(commands::instructions::InstructionsState::load());
            app.manage(services::attention::Attention::load());
            notices::setup(app.handle());
            companion::setup(app.handle());
            connectors::setup(app.handle());
            services::setup(app.handle());
            brain::setup(app.handle());
            agents::setup(app.handle());
            workspace::setup(app.handle());
            games::setup(app.handle());
            updates::setup(app.handle());
            services::start(app.handle());
            updates::start(app.handle());
            update_runner::start(app.handle());
            // OpenTelemetry export (Settings › Maintenance): off unless an endpoint is set.
            commands::services::telemetry_launched(app.handle());
            #[cfg(desktop)]
            games::start(app.handle());
            #[cfg(desktop)]
            {
                platform::desktop::setup(app.handle())?;
                // `nook --window` (bv. vanuit het startmenu) opent meteen het hoofdvenster.
                let args: Vec<String> = std::env::args().collect();
                if let Some(route) = platform::desktop::route_from_args(&args) {
                    platform::desktop::show_main(app.handle(), route);
                } else if app.state::<state::AppState>().settings().open_window_at_launch {
                    // Started at login (`--login` from autostart): the window opens behind the app you are in.
                    platform::desktop::open_at_launch(app.handle(), args.iter().any(|a| a == "--login"));
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
                    platform::desktop::closed_main(window.app_handle());
                    platform::desktop::remember_main(window.app_handle());
                    let _ = window.hide();
                } else if window.label().starts_with("tab-") {
                    platform::tab_windows::closed(window.app_handle(), window.label());
                }
            }
            #[cfg(not(desktop))]
            let _ = (window, event);
        })
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            #[cfg(desktop)]
            platform::tab_windows::open_tab_window,
            #[cfg(desktop)]
            platform::tab_windows::close_tab_window,
            #[cfg(desktop)]
            platform::tray_live::tray_live,
            #[cfg(desktop)]
            platform::desktop::quit_nook,
            platform::desktop::quit_now,
            workspace::clones::clone_jobs,
            keybindings::keybindings_read,
            keybindings::keybindings_write,
            storage::storage_incidents,
            services::attention::attention_record,
            services::attention::attention_weights,
            storage::storage_incident_dismiss,
            storage::storage_reveal,
            notice_history::notice_history,
            notice_history::notice_history_unseen,
            notice_history::notice_history_seen,
            notice_history::notice_history_remove,
            notice_history::notice_history_record,
            person_notes::person_note,
            person_notes::person_note_set,
            person_notes::birthdays_today,
            services::lyrics::music_lyrics,
            #[cfg(desktop)]
            platform::file_preview::file_preview,
            #[cfg(desktop)]
            platform::file_preview::file_open_in_app,
            workspace::clones::clone_hide,
            workspace::clones::clone_cancel,
            commands::get_settings,
            commands::bar_visible,
            commands::screen_names,
            commands::look_export,
            commands::look_read,
            diagnostics::diagnostics_report,
            notices::notice_decide,
            permissions::permissions_overview,
            permissions::permissions_open,
            diagnostics::diagnostics_show_logs,
            commands::instructions::instructions_view,
            commands::instructions::prompt_save,
            commands::instructions::prompt_remove,
            commands::instructions::space_save,
            commands::instructions::space_remove,
            commands::save_settings,
            commands::maintenance::maintenance_info,
            commands::maintenance::open_data_folder,
            commands::maintenance::clear_caches,
            commands::maintenance::export_settings,
            commands::maintenance::reset_settings,
            updates::update_status,
            updates::update_check,
            updates::update_install,
            updates::update_restart,
            updates::update_set_prefs,
            updates::update_dismiss,
            commands::providers,
            commands::openrouter_sign_in,
            commands::list_models,
            commands::key_status,
            commands::set_key,
            commands::nooks_list,
            commands::nooks_search,
            commands::search::search_everything,
            commands::search::search_ai_plan,
            commands::search::search_ai_answer,
            commands::search::search_open_note,
            commands::suggestions::suggest_actions,
            commands::suggestions::run_suggested_actions,
            commands::nook_get,
            commands::nook_active,
            commands::nook_new,
            commands::selection_ask::nook_new_background,
            commands::selection_ask::ask_about_selection,
            commands::nook_delete,
            commands::nook_set_flags,
            commands::ask,
            commands::stop,
            commands::queue_remove,
            commands::queue_move,
            commands::queue_send_now,
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
            commands::take_chat_terminal,
            commands::repair_start_menu_shortcut,
            commands::start_local_brain,
            commands::tray_status,
            commands::shortcut_problems,
            commands::read_answer_image,
            commands::companion::companion_info,
            commands::companion::companion_set_enabled,
            commands::companion::companion_begin_pairing,
            commands::companion::companion_cancel_pairing,
            commands::companion::companion_remove_device,
            commands::companion::companion_set_scopes,
            commands::companion::companion_set_push,
            commands::companion::companion_set_push_route,
            commands::companion::companion_set_apns,
            commands::companion::companion_remove_apns_key,
            commands::companion::companion_push_test,
            commands::companion::companion_set_relay,
            commands::companion::companion_test_relay,
            commands::companion::companion_set_keep_awake,
            commands::companion::companion_set_background,
            commands::companion::companion_client,
            commands::companion::companion_client_pair,
            commands::companion::companion_client_unpair,
            commands::companion::companion_client_refresh,
            commands::companion::companion_client_decide,
            commands::companion::companion_client_answer,
            commands::companion::companion_client_send,
            commands::companion::companion_client_stop,
            commands::companion::companion_client_deny,
            commands::companion::companion_client_switch,
            commands::companion::companion_client_push_keys,
            commands::companion::companion_client_register_push,
            commands::companion::companion_client_discard,
            commands::companion::companion_client_others,
            commands::companion::companion_client_call,
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
            commands::connectors::github_pull_request,
            commands::connectors::github_ci_log,
            commands::connectors::github_merge_pull_request,
            commands::connectors::github_review_pull_request,
            commands::connectors::github_actions_repos,
            commands::connectors::github_actions_workflows,
            commands::connectors::github_actions_runs,
            commands::connectors::github_actions_run,
            commands::connectors::github_actions_run_action,
            commands::connectors::github_actions_dispatch_form,
            commands::connectors::github_actions_dispatch,
            commands::connectors::pull_watch_add,
            commands::connectors::pull_watch_remove,
            commands::connectors::mcp_paste,
            commands::connectors::mcp_add,
            commands::connectors::mcp_remove,
            commands::connectors::mcp_set_enabled,
            commands::connectors::mcp_test,
            commands::connectors::mcp_connect_service,
            commands::connectors::mcp_sign_in,
            commands::connectors::connector_repair_sign_in,
            commands::connectors::gitlab_save,
            commands::connectors::gitlab_check,
            commands::connectors::gitlab_remove,
            commands::connectors::whatsapp_view,
            commands::connectors::whatsapp_save,
            commands::connectors::whatsapp_credential,
            commands::connectors::whatsapp_test,
            commands::connectors::whatsapp_chats,
            commands::connectors::whatsapp_chat_list,
            commands::connectors::whatsapp_reply,
            commands::connectors::whatsapp_mark_read,
            commands::connectors::whatsapp_ignore,
            commands::connectors::whatsapp_unmute,
            chats::helper::chat_helper_status,
            chats::inbox::chat_inbox_list,
            chats::inbox::chat_inbox_send_poll,
            chats::inbox::chat_inbox_vote,
            chats::gifs::chat_gifs,
            chats::gifs::chat_gif_file,
            chats::gifs::chat_giphy_key_set,
            chats::gifs::chat_giphy_key_save,
            chats::gifs::chat_giphy_key_remove,
            chats::inbox::chat_inbox_thread,
            chats::info::chat_common_groups,
            chats::info::chat_export,
            chats::inbox::chat_inbox_mark_read,
            chats::inbox::chat_inbox_mark_unread,
            chats::inbox::chat_inbox_mark_all_read,
            chats::inbox::chat_inbox_send,
            chats::inbox::chat_inbox_remove,
            chats::inbox::chat_inbox_message,
            chats::inbox::chat_inbox_older,
            chats::inbox::chat_inbox_in_app,
            chats::inbox::chat_inbox_send_file,
            chats::inbox::chat_inbox_people,
            chats::inbox::chat_link_preview,
            chats::inbox::chat_draft,
            chats::inbox::chat_suggest_reply,
            chats::follow_up::chat_owed,
            chats::follow_up::chat_follow_up_wait,
            chats::follow_up::chat_snooze,
            chats::follow_up::chat_snoozes,
            chats::follow_up::chat_schedule,
            chats::follow_up::chat_scheduled,
            chats::follow_up::chat_schedule_cancel,
            chats::link::chat_link_networks,
            chats::link::chat_link_start,
            chats::link::chat_link_session,
            chats::link::chat_link_submit,
            chats::link::chat_link_cancel,
            chats::link::chat_link_remove,
            chats::link::chat_link_sign_in,
            chats::call::chat_call_start,
            chats::call::chat_call_active,
            chats::call::chat_call_dismiss,
            chats::call::chat_call_open_app,
            commands::whatsapp::whatsapp_card,
            commands::whatsapp::whatsapp_card_load,
            commands::whatsapp::whatsapp_avatars,
            commands::whatsapp::whatsapp_accounts,
            commands::whatsapp::whatsapp_account_add,
            commands::whatsapp::whatsapp_account_remove,
            commands::whatsapp::whatsapp_account_rename,
            commands::whatsapp::whatsapp_account_retry,
            commands::whatsapp::whatsapp_gowa_state,
            commands::whatsapp::whatsapp_install_gowa,
            commands::whatsapp::whatsapp_open_file,
            commands::whatsapp::whatsapp_audio,
            commands::whatsapp::whatsapp_ask_nook,
            commands::whatsapp::whatsapp_mute,
            commands::whatsapp::whatsapp_set_mode,
            commands::whatsapp::whatsapp_unhide,
            commands::whatsapp::whatsapp_settings_chats,
            commands::connectors::chat_accounts,
            commands::connectors::chat_accounts_set,
            commands::connectors::service_icon,
            commands::connectors::agenda_upcoming,
            commands::games::games_list,
            commands::games::valorant_catalog,
            commands::games::valorant_view,
            commands::games::valorant_save_prefs,
            commands::games::valorant_start_match,
            commands::games::valorant_end_match,
            commands::games::valorant_set_match,
            commands::games::valorant_next_round,
            commands::games::valorant_record,
            commands::games::valorant_remove,
            commands::games::valorant_look,
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
            commands::services::screen_forget,
            commands::services::screen_status,
            commands::services::energy_status,
            commands::services::quiet_status,
            commands::services::screen_part_begin,
            commands::services::screen_part_image,
            commands::services::screen_part_finish,
            commands::services::screen_part_cancel,
            commands::services::today_items,
            commands::services::recap_view,
            commands::services::sound_file,
            commands::services::system_sounds,
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
            commands::brain::text_generator_test,
            commands::brain::brain_eval,
            commands::brain::brain_local_eval_questions,
            commands::brain::brain_local_eval_run,
            commands::brain::brain_local_eval_cancel,
            commands::brain::mail_update,
            commands::brain::mail_send,
            commands::brain::mail_open,
            commands::brain::mail_open_invite,
            commands::brain::mail_block_open,
            commands::brain::read_attachment,
            commands::brain::read_attachment_path,
            commands::brain::source_choices,
            commands::brain::set_scope,
            commands::brain::start_suggestions,
            commands::brain::retry_last,
            commands::brain::plan_edit,
            commands::brain::plan_include,
            commands::brain::plan_run_again,
            commands::agents::agents_overview,
            agents::usage::agents_usage_refresh,
            agents::usage::agents_codex_usage,
            agents::usage::agents_limits,
            agents::usage::agents_cliproxy_hubs,
            agents::usage::agents_cliproxy_add,
            agents::usage::agents_cliproxy_remove,
            agents::usage::agents_cliproxy_refresh,
            agents::updates::agents_updates,
            agents::updates::agents_update,
            agents::usage::agents_use_reset_credit,
            commands::agents::agents_decide,
            commands::agents::agents_deny,
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
            commands::agents::agents_granted_rules,
            commands::agents::agents_revoke_rule,
            commands::agents::agents_revoke_project_rules,
            commands::agents::agents_approval_audit,
            commands::agents::agents_clear_approval_audit,
            commands::agents::agents_apply_link,
            commands::agents::agents_discard_link,
            commands::agents::agents_profiles,
            commands::agents::agents_profile_add,
            commands::agents::agents_profile_rename,
            commands::agents::agents_profile_remove,
            commands::agents::agents_profile_prefer,
            commands::agents::agents_profile_auth,
            commands::agents::agents_profile_key,
            commands::agents::agents_profile_set_enabled,
            commands::agents::agents_profile_set_executable_path,
            commands::agents::agents_profile_set_extra_arguments,
            commands::agents::agents_profile_set_variables,
            commands::agents::agents_profile_set_custom_models,
            commands::agents::agents_mark_finished,
            commands::agents::agents_visit,
            commands::agents::agents_activate_terminal,
            commands::agents::agents_run_in_terminal,
            commands::agents::agents_terminal_name,
            commands::agents::agents_sound,
            commands::workspace::workspace_overview,
            commands::session_cards::workspace_suggestion_chosen,
            commands::session_cards::workspace_page_html,
            commands::workspace::workspace_save_settings,
            commands::workspace::workspace_project_settings,
            commands::workspace::workspace_set_project_settings,
            commands::workspace::workspace_forget_project,
            commands::workspace::workspace_toggle_favorite_project,
            commands::workspace::workspace_timeline,
            commands::workspace::workspace_queue,
            commands::workspace::workspace_inspect,
            commands::workspace::workspace_start,
            commands::workspace::workspace_keep_scratch,
            commands::workspace::workspace_clear,
            commands::workspace::workspace_resources,
            commands::workspace::workspace_search,
            commands::workspace::workspace_models,
            commands::workspace::workspace_model_list_date,
            commands::workspace::workspace_prompts,
            commands::workspace::workspace_save_prompt,
            commands::workspace::workspace_delete_prompt,
            commands::workspace::workspace_files,
            commands::workspace::workspace_skills,
            commands::workspace::workspace_fork,
            commands::workspace::workspace_apply_hunk,
            commands::file_view::workspace_file_read,
            commands::workspace_tools::workspace_dev_servers,
            commands::workspace_tools::workspace_stop_dev_server,
            commands::file_view::workspace_file_save,
            commands::workspace::workspace_save_picture,
            commands::workspace::workspace_favicon,
            commands::workspace::workspace_agent_commands,
            commands::workspace::antigravity_setup,
            commands::workspace::antigravity_install,
            commands::workspace::antigravity_uninstall,
            commands::workspace::workspace_save_markdown,
            commands::workspace::workspace_init_git,
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
            commands::workspace::workspace_continue_interrupted,
            commands::workspace::workspace_dismiss_question,
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
            commands::workspace::workspace_set_goal,
            commands::workspace::workspace_context_usage,
            commands::workspace::workspace_worktrees,
            commands::workspace::workspace_remove_worktree,
            commands::workspace::workspace_agent_versions,
            commands::workspace::workspace_skills_catalog,
            commands::workspace::workspace_read_skill,
            commands::workspace::workspace_toggle_skill,
            commands::workspace::workspace_open_skills_folder,
            commands::workspace::workspace_worktree_cleanup_status,
            commands::workspace::workspace_worktree_cleanup_now,
            commands::workspace::workspace_reveal_path,
            commands::services::telemetry_status,
            commands::services::telemetry_save_headers,
            commands::services::telemetry_test,
            commands::mail::mail_accounts_list,
            commands::mail::mail_microsoft_start,
            commands::mail::mail_microsoft_finish,
            commands::mail::mail_google_sign_in,
            commands::mail::mail_account_set_calendar,
            commands::mail::mail_account_rename,
            commands::mail::mail_account_remove,
            commands::mail::mail_save_client_config,
            commands::mail::mail_send_linked,
            commands::workspace::workspace_continue_live,
            commands::workspace::workspace_quick,
            commands::workspace::workspace_clone,
            commands::workspace::workspace_create_project,
            commands::workspace::workspace_publish_plan,
            commands::workspace::workspace_publish_repository,
            commands::workspace::workspace_project_icon_save,
            commands::workspace::workspace_pull,
            commands::workspace::workspace_start_branch,
            commands::workspace::workspace_move_onto_base,
            commands::workspace::workspace_commit_all,
            commands::workspace::workspace_pull_request_draft,
            commands::workspace::workspace_create_pull_request,
            commands::workspace::workspace_continue_past,
            commands::workspace::workspace_tuning_scan,
            commands::workspace::workspace_tuning_set,
            commands::workspace::workspace_readiness,
            commands::workspace::workspace_limit_advice,
            commands::workspace::workspace_offers_compact_first,
            commands::automation::automation_overview,
            commands::automation::automation_save_settings,
            commands::automation::automation_save_task,
            commands::automation::automation_delete_task,
            commands::automation::automation_set_task_enabled,
            commands::automation::automation_run_task,
            commands::automation::automation_webhook_secret,
            commands::automation::workspace_hand_off,
            commands::automation::workspace_delegation,
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
            commands::workspace_tools::workspace_editors,
            commands::workspace_tools::workspace_open_in,
            commands::workspace_tools::workspace_terminals,
            commands::workspace_tools::workspace_open_terminal,
            commands::workspace_tools::open_in_prefs,
            commands::workspace_tools::open_in_set_prefs,
            commands::workspace_tools::browser_history_count,
            commands::workspace_tools::browser_history_clear,
            commands::workspace_tools::browser_history_suggest,
            commands::search::buddy_moment,
            commands::search::buddy_breathe,
            commands::whatsapp::chat_forward,
            commands::whatsapp::chat_abilities,
            commands::whatsapp::chat_mark_unread,
            commands::whatsapp::chat_set_pinned,
            commands::whatsapp::chat_set_muted,
            commands::whatsapp::chat_set_archived,
            commands::whatsapp::chat_delete,
            commands::whatsapp::chat_ask_nook,
            commands::workspace::workspace_side_chat,
            workspace::bridge::bridge_submit_secret,
            chats::inbox::chat_inbox_edit_message,
            chats::inbox::chat_inbox_delete_for_everyone,
            chats::inbox::chat_inbox_delete_for_me,
            chats::inbox::chat_inbox_message_info,
            chats::inbox::chat_inline_nook,
            commands::search::music_overview,
            commands::search::music_search,
            commands::search::music_queue,
            commands::search::music_queue_add,
            commands::search::music_playlists,
            commands::search::music_playlist_create,
            commands::search::music_playlist_modify,
            commands::search::music_library,
            commands::search::music_history_stats,
            commands::search::music_outputs,
            commands::search::music_select_output,
            commands::search::music_spotify_connect,
            commands::search::music_spotify_disconnect,
            commands::search::voice_dictation_languages,
            commands::search::voice_reusable_models,
            commands::services::secrets_onepassword_status,
            commands::services::secrets_onepassword_resolve,
            commands::services::handle_deep_link,
            commands::workspace::workspace_regenerate_title,
            commands::workspace::workspace_suggest_next_prompt,
            commands::workspace::workspace_governor_status,
            commands::workspace::workspace_governor_let_go_on,
            commands::workspace_tools::browser_pick_element,
            commands::workspace_tools::browser_cancel_pick,
            commands::workspace_tools::browser_clear_picks,
            commands::workspace_tools::browser_elements,
            commands::workspace_tools::workspace_pr_local_folder,
            commands::workspace_tools::workspace_pr_checkout,
            commands::workspace_tools::workspace_worktree_disk_status,
            commands::workspace_tools::workspace_build_leftovers_scan,
            commands::workspace_tools::workspace_build_leftovers_sweep,
            commands::workspace_tools::workspace_worktree_archive,
            commands::workspace_tools::workspace_worktree_move,
        ])
        .build(tauri::generate_context!())
        .expect("Nook kon niet starten")
        .run(|app, event| {
            #[cfg(desktop)]
            if let tauri::RunEvent::ExitRequested { .. } = event {
                platform::desktop::remember_main(app);
            }
            if let tauri::RunEvent::Exit = event {
                // Bij afsluiten: de WhatsApp-gateway en lopende agents van de werkruimte netjes stoppen.
                connectors::shutdown(app);
                workspace::shutdown(app);
                update_runner::clean_exit();
            }
        });
}
