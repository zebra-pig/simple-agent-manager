import type { McpInstructionContextType } from './mcp-token';

export interface VisibleInitialPromptAttachment {
  uploadId?: string;
  filename: string;
  size: number;
  contentType: string;
}

export interface BuildVisibleInitialPromptInput {
  message: string;
  attachments?: VisibleInitialPromptAttachment[] | null;
  systemPromptAppend?: string | null;
}

export function buildVisibleInitialPrompt(input: BuildVisibleInitialPromptInput): string {
  let attachmentContext = '';
  if (input.attachments?.length) {
    const fileList = input.attachments
      .map(
        (a) =>
          `- \`/workspaces/.private/${a.uploadId ? `${a.uploadId}/` : ''}${a.filename}\` (${a.size} bytes, ${a.contentType})`
      )
      .join('\n');
    attachmentContext =
      `\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n${fileList}\n` +
      `\nThese are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.\n`;
  }

  const systemPromptSuffix = input.systemPromptAppend ? `\n\n${input.systemPromptAppend}` : '';

  return `${input.message}${attachmentContext}${systemPromptSuffix}`;
}

/**
 * The first user message as the chat persists it: the typed text plus the same
 * attached-files list the agent's first prompt carries (no profile system append),
 * matching what follow-up messages persist. Clients render attachments from this
 * list, so without it a new chat shows no files until the agent echoes its prompt.
 * A fork's agent prompt is plain (its files travel in the historical context), so
 * a fork's message stays plain too and the agent echo still deduplicates.
 */
export function buildVisibleInitialMessage(input: {
  message: string;
  attachments?: VisibleInitialPromptAttachment[] | null;
  forked?: boolean;
}): string {
  if (input.forked || !input.attachments?.length) return input.message;
  return buildVisibleInitialPrompt({ message: input.message, attachments: input.attachments });
}

export function buildSamBootstrapInstructions(_input: {
  contextType: McpInstructionContextType;
}): string {
  return (
    `IMPORTANT: Before starting any work, you MUST call the \`get_instructions\` tool from the sam-mcp MCP server. ` +
    `This provides your task context, project information, output branch name, and instructions for reporting progress. ` +
    `Do not proceed until you have called this tool and read its response.`
  );
}
