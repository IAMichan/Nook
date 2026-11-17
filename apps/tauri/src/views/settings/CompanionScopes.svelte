<script lang="ts">
  // One switch per scope: what a phone may do from afar (`CompanionScopeToggles` on the Mac). Shared by pairing (the
  // phone that pairs next) and a paired phone's row.
  import { COMPANION_SCOPES, withScope, type CompanionScope } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";

  let { scopes, onchange }: { scopes: CompanionScope[]; onchange: (scopes: CompanionScope[]) => void } = $props();

  function label(scope: CompanionScope): string {
    switch (scope) {
      case "read":
        return tr("Sessies, gesprekken, Vandaag en verbruik zien", "See sessions, conversations, Today and usage");
      case "approve":
        return tr("Goedkeuren, weigeren en vragen beantwoorden", "Approve, deny and answer questions");
      case "operate":
        return tr("Sessies starten, berichten sturen, stoppen en beheren", "Start sessions, send messages, stop and manage them");
      case "chats":
        return tr("Chats lezen en beantwoorden", "Read and answer chats");
      case "music":
        return tr("Muziek bedienen", "Control music");
      case "nookChat":
        return tr("Met Nook chatten", "Chat with Nook");
    }
  }
</script>

{#each COMPANION_SCOPES as scope (scope)}
  <label class="row">
    <span>{label(scope)}</span>
    <input type="checkbox" checked={scopes.includes(scope)} onchange={(e) => onchange(withScope(scopes, scope, e.currentTarget.checked))} />
  </label>
{/each}
