// What the Chats tab tells the main window about its layout. With no chat app on yet the Mac folds the window's
// sidebar to a rail of icons and puts the footer under the page (`ChatsTab.empty`); `folded` says when.
class ChatsShell {
  /** True while the Chats tab shows its empty page: the sidebar may fold to the icon rail. */
  folded = $state(false);
}

export const chatsShell = new ChatsShell();
