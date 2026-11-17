//! The shared chat inbox in the app: Nook's chat helper (nook-chatd) and its bridge, read into
//! [`nook_core::chats::InboxStore`]. The interface hears of changes through the `chats-changed` event.

pub mod helper;
