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

/// This source tree is the mattstack fork (m4ttstack/herdr). Every build of it is
/// the fork, whether or not it was built by `ms/build.sh`.
const FORK_SOURCE: bool = true;

/// What a build of this source is to the updater.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fork {
    /// Stock herdr: not built from the fork's source.
    None,
    /// A fork release from `ms/build.sh` (channel `ms`), which updates from m4ttstack/herdr.
    Release,
    /// The fork's source built some other way, such as a plain `cargo build`: no
    /// release matches it, so it never updates itself.
    Unreleased,
}

pub fn fork() -> Fork {
    fork_for(FORK_SOURCE, channel())
}

/// True for any build of the fork's source, which never updates from herdr.dev.
pub fn is_fork() -> bool {
    fork() != Fork::None
}

fn fork_for(fork_source: bool, channel: &str) -> Fork {
    match (fork_source, is_fork_channel(channel)) {
        (false, _) => Fork::None,
        (true, true) => Fork::Release,
        (true, false) => Fork::Unreleased,
    }
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

    #[test]
    fn a_build_of_the_fork_source_without_the_ms_channel_is_unreleased() {
        use super::Fork;
        assert_eq!(super::fork_for(true, "ms"), Fork::Release);
        assert_eq!(super::fork_for(true, "stable"), Fork::Unreleased);
        assert_eq!(super::fork_for(true, "preview"), Fork::Unreleased);
        assert_eq!(super::fork_for(false, "stable"), Fork::None);
    }

    #[test]
    fn this_source_is_the_fork() {
        assert_ne!(super::fork(), super::Fork::None);
        assert!(super::is_fork());
    }
}
