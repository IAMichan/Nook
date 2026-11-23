//! The words a recogniser is told to expect (`DictationContext` on the Mac and the iPhone): your personal dictionary
//! first, then the names of your projects and branches, so "Nook" and "login-flow" are heard as you write them. On
//! Windows they go to whisper.cpp (`--prompt`), to OpenAI and Groq (`prompt`) and to the clean-up that follows.
//!
//! The Mac does not read the text field or the screen for dictation either: this context is names, nothing from the
//! field you type in.

/// Keep the list short; more words slow recognition down without helping it.
pub const LIMIT: usize = 100;
pub const MAX_LENGTH: usize = 60;

/// The dictionary words, then the names (with a spoken variant for `kebab-case`, `snake_case` and `a/b`), each once, at
/// most [`LIMIT`]. A branch prefix such as `nook/` is dropped: nobody says it.
pub fn strings(dictionary: &[String], projects: &[String], branches: &[String]) -> Vec<String> {
    struct List {
        out: Vec<String>,
        seen: std::collections::HashSet<String>,
    }
    impl List {
        fn add(&mut self, raw: &str) {
            let word = raw.trim();
            if word.is_empty() || word.chars().count() > MAX_LENGTH || self.out.len() >= LIMIT || !self.seen.insert(word.to_lowercase()) {
                return;
            }
            self.out.push(word.to_string());
        }
        fn add_name(&mut self, raw: &str) {
            self.add(raw);
            let spoken = raw.replace(['-', '_', '/'], " ");
            if spoken != raw {
                self.add(&spoken);
            }
        }
    }
    let mut list = List { out: vec![], seen: Default::default() };
    for word in dictionary {
        list.add(word);
    }
    for project in projects {
        list.add_name(project);
    }
    for branch in branches {
        let parts: Vec<&str> = branch.split('/').filter(|p| !p.is_empty()).collect();
        if parts.len() > 1 {
            list.add_name(&parts[1..].join("/"));
        } else {
            list.add_name(branch);
        }
    }
    list.out
}

/// The last folder of a path, for a project's name.
pub fn folder_name(path: &str) -> String {
    path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or("").to_string()
}

/// The words as one hint for whisper.cpp or a cloud service (their `prompt`): a short sentence-less list.
pub fn prompt(words: &[String]) -> String {
    words.iter().take(40).cloned().collect::<Vec<_>>().join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn dictionary_first_then_projects_and_branches_without_duplicates() {
        let out = strings(&v(&["Nook", "Claude Code"]), &v(&["login-flow", "nook"]), &v(&["nook/fix_login", "main"]));
        assert_eq!(out, v(&["Nook", "Claude Code", "login-flow", "login flow", "fix_login", "fix login", "main"]));
    }

    #[test]
    fn long_and_empty_entries_are_left_out_and_the_list_is_capped() {
        let long = "x".repeat(MAX_LENGTH + 1);
        assert!(strings(&v(&["", "  ", &long]), &[], &[]).is_empty());
        let many: Vec<String> = (0..300).map(|n| format!("word{n}")).collect();
        assert_eq!(strings(&many, &[], &[]).len(), LIMIT);
    }

    #[test]
    fn names_and_prompt() {
        assert_eq!(folder_name(r"C:\Users\me\Code\nook\"), "nook");
        assert_eq!(folder_name("/home/me/nook"), "nook");
        assert_eq!(prompt(&v(&["a", "b"])), "a, b");
    }
}
