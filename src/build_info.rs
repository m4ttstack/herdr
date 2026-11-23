//! Build identity helpers.

pub const BASE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn channel() -> &'static str {
    non_empty(option_env!("HERDR_BUILD_CHANNEL")).unwrap_or("stable")
}

pub fn build_id() -> Option<&'static str> {
    non_empty(option_env!("HERDR_BUILD_ID"))
}

pub fn version() -> String {
    match channel() {
        "stable" => BASE_VERSION.to_string(),
        channel => match build_id() {
            Some(build_id) => format!("{BASE_VERSION}-{channel}.{build_id}"),
            None => format!("{BASE_VERSION}-{channel}"),
        },
    }
}

pub fn is_preview() -> bool {
    channel() == "preview"
}

/// True for a mattstack fork build (m4ttstack/herdr), which updates only from the fork.
pub fn is_fork() -> bool {
    is_fork_channel(channel())
}

/// The fork revision `n` of a `<base>-ms.<n>` build.
pub fn fork_revision() -> Option<u32> {
    fork_revision_for(channel(), build_id())
}

fn is_fork_channel(channel: &str) -> bool {
    channel == "ms"
}

fn fork_revision_for(channel: &str, build_id: Option<&str>) -> Option<u32> {
    if !is_fork_channel(channel) {
        return None;
    }
    build_id?.parse().ok()
}

fn non_empty(value: Option<&'static str>) -> Option<&'static str> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn stable_version_defaults_to_cargo_version() {
        assert!(!super::version().is_empty());
    }

    #[test]
    fn fork_revision_reads_the_ms_build_id() {
        assert_eq!(super::fork_revision_for("ms", Some("7")), Some(7));
        assert_eq!(super::fork_revision_for("ms", Some("x")), None);
        assert_eq!(super::fork_revision_for("ms", None), None);
        assert_eq!(super::fork_revision_for("preview", Some("7")), None);
        assert_eq!(super::fork_revision_for("stable", None), None);
    }

    #[test]
    fn only_the_ms_channel_is_the_fork() {
        assert!(super::is_fork_channel("ms"));
        assert!(!super::is_fork_channel("stable"));
        assert!(!super::is_fork_channel("preview"));
    }
}
