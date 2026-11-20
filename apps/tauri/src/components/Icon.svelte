<script lang="ts" module>
  // The app's short icon names, each the Lucide icon the Mac draws for the same thing (`NookIcon.table`): the Mac names
  // its icons the SF Symbol way and translates them to Lucide, so the same table here keeps every icon the Mac's.
  export const ICON_LUCIDE = {
    chat: "message-square",
    agents: "terminal",
    workspace: "layout-grid",
    phone: "smartphone",
    settings: "settings",
    plus: "plus",
    search: "search",
    sidebar: "panel-left",
    arrow: "arrow-up",
    back: "chevron-left",
    attach: "paperclip",
    mic: "mic",
    copy: "copy",
    lock: "lock",
    unlock: "lock-open",
    gamepad: "gamepad-2",
    home: "house",
    memory: "library",
    link: "link",
    brain: "brain",
    pull: "git-pull-request",
    chart: "chart-column",
    globe: "globe",
    note: "notebook-pen",
    voice: "audio-lines",
    check: "check",
    calendar: "calendar",
    message: "message-circle",
    code: "code",
    sparkle: "sparkles",
    x: "x",
    grip: "grip-vertical",
    tasks: "list-checks",
    terminal: "terminal",
    file: "file",
    pencil: "pencil",
    bot: "bot",
    wrench: "wrench",
    "chevron-right": "chevron-right",
    "chevron-down": "chevron-down",
    alert: "triangle-alert",
    loader: "loader-circle",
    stop: "square",
    branch: "git-branch",
    eye: "eye",
    hand: "hand",
    "circle-check": "circle-check",
    hourglass: "hourglass",
    palette: "palette",
    keyboard: "keyboard",
    archive: "archive",
    bell: "bell",
    clock: "clock",
    play: "play",
    pause: "pause",
    wrap: "wrap-text",
    image: "image",
  } as const;
  export type IconName = keyof typeof ICON_LUCIDE;
</script>

<script lang="ts">
  // A named icon of the app, drawn as its Lucide icon (`Ico`), the one the Mac shows for it.
  import Ico from "./ui/Ico.svelte";
  let { name, size = 18 }: { name: IconName; size?: number } = $props();
</script>

<Ico name={ICON_LUCIDE[name]} {size} stroke={size >= 20 ? 1.75 : 2} />
