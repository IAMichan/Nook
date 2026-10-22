import type { Conversation } from "./types";

type ExportConversation = Pick<Conversation, "title"> & {
  messages: Pick<Conversation["messages"][number], "id" | "text" | "fromUser" | "streaming" | "attachment">[];
};

export function conversationMarkdown(conversation: ExportConversation, streaming: Readonly<Record<string, string>> = {}): string {
  const messages = conversation.messages.map((message) => {
    const text = message.streaming ? streaming[message.id] ?? message.text : message.text;
    return [`## ${message.fromUser ? "You" : "Nook"}`, message.attachment ? `Attachment: ${message.attachment}` : "", text].filter(Boolean).join("\n\n");
  });
  return [`# ${conversation.title}`, ...messages].join("\n\n");
}
