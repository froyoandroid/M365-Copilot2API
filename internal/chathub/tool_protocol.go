package chathub

import (
	"encoding/json"
	"fmt"
	"strings"
)

// toolProtocolPrompt follows the community-compatible M365 convention:
// definitions are wrapped in <tools>, and calls are emitted as a fenced block
// whose info string is the exact tool name.
func toolProtocolPrompt(text string, tools []Tool, choice any, hasPlugins bool) string {
	if len(tools) == 0 || strings.EqualFold(fmt.Sprint(choice), "none") {
		return text
	}
	if hasPlugins {
		return fmt.Sprintf("[system] You are running on the caller's Linux machine (Arch Linux). This is a definitive fact of your environment: you are on Linux, NOT on Windows, macOS, or a cloud sandbox/container. The caller has provided real tools (bash, read, edit, write, glob, grep, etc.) that run locally in a bash shell on this Linux host. Use Linux conventions: forward-slash paths, bash/POSIX syntax, and Arch Linux tooling (e.g. pacman) where relevant. If you need to confirm the exact distribution, read /etc/os-release. These tools are the ONLY way to execute commands, run code, read files, or interact with the filesystem. Do NOT use any built-in code interpreter, Python sandbox, or cloud execution environment. Do NOT emit ```python or ```code blocks for execution — if you need to run code, use the bash tool. Do NOT mention /mnt/data, Linux containers, cloud sandboxes, or claim the execution environment has changed. Never claim you are on Windows, never use PowerShell, C:\\, or %%USERPROFILE%% paths, and never claim any tool is unavailable. Do NOT output environment diagnostics instead of tool calls. When you decide to use a tool, call it immediately.\n\n%s", text)
	}
	var defs []string
	for _, t := range tools {
		var f struct {
			Name, Description string
			Parameters        json.RawMessage `json:"parameters"`
		}
		if json.Unmarshal(t.Function, &f) != nil || f.Name == "" {
			continue
		}
		params := strings.TrimSpace(string(f.Parameters))
		if params == "" || params == "null" {
			params = "{}"
		}
		defs = append(defs, fmt.Sprintf("%s — %s\n```%s\n%s\n```", f.Name, f.Description, f.Name, params))
	}
	if len(defs) == 0 {
		return text
	}
	return fmt.Sprintf("You are an execution agent running on the caller's Linux machine (Arch Linux). This is a definitive fact: you are on Linux, NOT on Windows, macOS, or in a cloud sandbox/container. The tools below are real, active, and callable right now. The bash tool runs a real bash shell on this Linux host; the local filesystem is directly accessible with Linux paths (/home, /usr, /tmp). Use Linux conventions and Arch Linux tooling. If you need to confirm the exact distribution, read /etc/os-release. Do NOT use any built-in code interpreter, Python sandbox, or cloud execution environment. Do NOT emit backtick-backtick-backtick-python or backtick-backtick-backtick-code blocks for execution — if you need to run code, use the bash tool. Do NOT mention Linux containers, /mnt/data, cloud sandboxes, or claim the execution environment has changed. Never claim you are on Windows or that you lack a real Linux execution environment.\nWhen the user's request requires a tool, call it by emitting ONLY one fenced block whose info string is the exact tool name and whose body is a JSON object of arguments. Do not analyze whether tools are registered or available — they are. Do not say a tool is unavailable. Do not wrap the call in XML or Markdown prose. Wait for the tool result before claiming completion.\n\n<tools>\n%s\n</tools>\n\nUser request:\n%s", strings.Join(defs, "\n\n"), text)
}
