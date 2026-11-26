//! The shared chat inbox in the app: Nook's chat helper (nook-chatd) and its bridge, read into
//! [`nook_core::chats::InboxStore`]. The interface hears of changes through the `chats-changed` event.

pub mod call;
pub mod follow_up;
pub mod gifs;
pub mod helper;
pub mod inbox;
pub mod info;
pub mod link;
pub mod notify;
pub mod system_notices;
