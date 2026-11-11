// Guards for the scenario test bundle (docs/SCENARIOS.md), in C so they hold on any commit the scenarios are laid over.
//
// The bundle compiles the app's own sources. A function defined here wins over the system's at link time for every call
// from those sources (the linker takes a definition in an object file before one in a dylib), so:
//
// - The Keychain is never touched: SecItem* answer "not found" and store nothing. An unsigned test process reading the
//   items Nook stored would make macOS ask the user for their password.
// - posix_spawn refuses a real coding agent. Only the replay agent (NOOK_SCENARIO_SHIM) may run under an agent's name;
//   anything else under such a name, or a shell asked to run one, is refused and written to the scenario home's
//   guard log, which the harness turns into a scenario that could not run. (Foundation's Process is guarded in Swift.)
#include <dlfcn.h>
#include <errno.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t ScenarioOSStatus;
static const ScenarioOSStatus scenarioItemNotFound = -25300; // errSecItemNotFound

ScenarioOSStatus SecItemCopyMatching(const void *query, const void **result) {
    (void)query;
    if (result) *result = NULL;
    return scenarioItemNotFound;
}

ScenarioOSStatus SecItemAdd(const void *attributes, const void **result) {
    (void)attributes;
    if (result) *result = NULL;
    return 0; // Pretends it stored it; nothing is written.
}

ScenarioOSStatus SecItemUpdate(const void *query, const void *attributes) {
    (void)query;
    (void)attributes;
    return scenarioItemNotFound;
}

ScenarioOSStatus SecItemDelete(const void *query) {
    (void)query;
    return 0;
}

// MARK: Agents

static const char *scenarioAgentNames[] = {
    "claude", "claude.exe", "codex", "gemini", "opencode", "cursor-agent", "grok", "antigravity", "pi", "qwen",
    "goose", "amp", "auggie", "kiro-cli", "droid", NULL,
};

static int scenarioIsAgentName(const char *name) {
    for (int index = 0; scenarioAgentNames[index]; index++) {
        if (strcmp(name, scenarioAgentNames[index]) == 0) return 1;
    }
    return 0;
}

static const char *scenarioBaseName(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/// Whether a shell command line names an agent as a word.
static int scenarioMentionsAgent(const char *line) {
    for (int index = 0; scenarioAgentNames[index]; index++) {
        const char *name = scenarioAgentNames[index];
        size_t length = strlen(name);
        for (const char *found = strstr(line, name); found; found = strstr(found + 1, name)) {
            char before = found == line ? ' ' : found[-1];
            char after = found[length];
            int startsWord = before == ' ' || before == '/' || before == ';' || before == '&' || before == '|' || before == '(' || before == '\'' || before == '"';
            int endsWord = after == '\0' || after == ' ' || after == ';' || after == '&' || after == '|' || after == ')' || after == '\'' || after == '"' || after == '\n';
            if (startsWord && endsWord) return 1;
        }
    }
    return 0;
}

/// 1 when the program may run: the replay agent itself, or anything that is not an agent.
int nook_scenario_spawn_allowed(const char *path, char *const argv[]) {
    if (!path) return 1;
    const char *shim = getenv("NOOK_SCENARIO_SHIM");
    if (shim && strcmp(path, shim) == 0) return 1;
    if (scenarioIsAgentName(scenarioBaseName(path))) return 0;
    const char *base = scenarioBaseName(path);
    int shell = strcmp(base, "sh") == 0 || strcmp(base, "zsh") == 0 || strcmp(base, "bash") == 0 || strcmp(base, "fish") == 0
        || strcmp(base, "env") == 0;
    if (shell && argv) {
        for (int index = 1; argv[index]; index++) {
            if (strcmp(base, "env") == 0 && scenarioIsAgentName(scenarioBaseName(argv[index]))) return 0;
            if (shell && strcmp(base, "env") != 0 && scenarioMentionsAgent(argv[index])) return 0;
        }
    }
    return 1;
}

static void scenarioRecordRefusal(const char *path, char *const argv[]) {
    const char *home = getenv("NOOK_SCENARIO_HOME");
    if (!home) return;
    char log[4096];
    snprintf(log, sizeof log, "%s/guard-violations.log", home);
    FILE *file = fopen(log, "a");
    if (!file) return;
    fprintf(file, "spawn refused: %s", path ? path : "(null)");
    for (int index = 1; argv && argv[index] && index < 8; index++) fprintf(file, " %.200s", argv[index]);
    fprintf(file, "\n");
    fclose(file);
}

typedef int (*ScenarioSpawn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                             char *const[], char *const[]);

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
                char *const argv[], char *const envp[]) {
    if (!nook_scenario_spawn_allowed(path, argv)) {
        scenarioRecordRefusal(path, argv);
        return EPERM;
    }
    static ScenarioSpawn real = NULL;
    if (!real) real = (ScenarioSpawn)dlsym(RTLD_NEXT, "posix_spawn");
    return real(pid, path, actions, attributes, argv, envp);
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
                 char *const argv[], char *const envp[]) {
    if (!nook_scenario_spawn_allowed(file, argv)) {
        scenarioRecordRefusal(file, argv);
        return EPERM;
    }
    static ScenarioSpawn real = NULL;
    if (!real) real = (ScenarioSpawn)dlsym(RTLD_NEXT, "posix_spawnp");
    return real(pid, file, actions, attributes, argv, envp);
}
