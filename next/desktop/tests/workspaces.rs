use expert_desktop::{
    files::{MAX_FILE_BYTES, WorkspaceFiles, validate_relative},
    workspace::{Access, WorkspaceStore},
};
use std::fs;
use tempfile::TempDir;

struct Fixture {
    temp: TempDir,
    store: WorkspaceStore,
    files: WorkspaceFiles,
}

#[test]
fn default_workspace_is_dedicated_and_preserves_updated_permissions() {
    let temp = TempDir::new().unwrap();
    let store = WorkspaceStore::open(temp.path().join("state")).unwrap();
    let first = store.default_workspace().unwrap();
    assert_eq!(first.id, "builtin-default");
    assert_eq!(first.access_at(&first.root), Access::ReadWrite);
    assert!(!first.root.starts_with(store.directory()));
    let files = WorkspaceFiles::new(store.clone(), first.id.clone()).unwrap();
    files.write("root", "draft.txt", "draft", "new").unwrap();
    store
        .set_scope(&first.id, "root", &first.root, Access::ReadOnly)
        .unwrap();
    assert_eq!(
        store.default_workspace().unwrap().access_at(&first.root),
        Access::ReadOnly
    );
    assert!(files.write("root", "next.txt", "no", "new").is_err());
    assert!(store.remove(&first.id).is_err());
    assert!(
        store
            .add(
                "builtin-default",
                "override",
                &first.root,
                Access::ReadWrite
            )
            .is_err()
    );
    assert_eq!(files.read("root", "draft.txt").unwrap().content, "draft");
}

impl Fixture {
    fn new(access: Access) -> Self {
        let temp = TempDir::new().unwrap();
        let project = temp.path().join("project");
        fs::create_dir_all(project.join("src")).unwrap();
        fs::create_dir_all(project.join("private")).unwrap();
        fs::write(project.join("src/main.txt"), "original\n").unwrap();
        fs::write(project.join("private/secret.txt"), "private data").unwrap();
        let store = WorkspaceStore::open(temp.path().join("state")).unwrap();
        store.add("example", "Example", &project, access).unwrap();
        let files = WorkspaceFiles::new(store.clone(), "example".into()).unwrap();
        Self { temp, store, files }
    }

    fn project(&self) -> std::path::PathBuf {
        self.temp.path().join("project")
    }
}

#[test]
fn readonly_workspace_reads_but_cannot_write_or_create_directories() {
    let f = Fixture::new(Access::ReadOnly);
    let read = f.files.read("root", "src/main.txt").unwrap();
    assert_eq!(read.content, "original\n");
    assert!(
        f.files
            .write("root", "src/main.txt", "changed", &read.sha256)
            .is_err()
    );
    assert!(f.files.create_directory("root", "new-dir").is_err());
    assert_eq!(
        fs::read_to_string(f.project().join("src/main.txt")).unwrap(),
        "original\n"
    );
}

#[test]
fn child_write_grant_works_without_widening_parent_or_external_access() {
    let f = Fixture::new(Access::ReadOnly);
    f.store
        .set_scope(
            "example",
            "source",
            &f.project().join("src"),
            Access::ReadWrite,
        )
        .unwrap();
    f.files.write("root", "src/new.txt", "new", "new").unwrap();
    assert!(f.files.write("root", "outside.txt", "new", "new").is_err());
    assert!(f.files.read("unregistered", "src/main.txt").is_err());
}

#[test]
fn nested_rules_prevent_access_through_parent_scope() {
    let f = Fixture::new(Access::ReadWrite);
    f.store
        .set_scope(
            "example",
            "private",
            &f.project().join("private"),
            Access::Deny,
        )
        .unwrap();
    f.store
        .set_scope(
            "example",
            "source",
            &f.project().join("src"),
            Access::ReadOnly,
        )
        .unwrap();
    assert!(f.files.read("root", "private/secret.txt").is_err());
    assert!(f.files.read("private", "secret.txt").is_err());
    assert!(f.files.write("root", "src/new.txt", "no", "new").is_err());
    assert!(
        !f.files
            .list("root", ".")
            .unwrap()
            .entries
            .iter()
            .any(|e| e.name == "private")
    );
}

#[test]
fn revocation_applies_to_an_already_constructed_executor() {
    let f = Fixture::new(Access::ReadWrite);
    f.files
        .write("root", "src/new.txt", "first", "new")
        .unwrap();
    f.store
        .set_scope("example", "root", &f.project(), Access::ReadOnly)
        .unwrap();
    assert!(
        f.files
            .write("root", "src/next.txt", "second", "new")
            .is_err()
    );
    f.store.remove("example").unwrap();
    assert!(f.files.read("root", "src/main.txt").is_err());
    assert!(f.project().join("src/new.txt").exists());
}

#[test]
fn external_directory_requires_its_own_grant() {
    let f = Fixture::new(Access::ReadOnly);
    let external = f.temp.path().join("reference");
    fs::create_dir(&external).unwrap();
    fs::write(external.join("guide.txt"), "reference").unwrap();
    assert!(f.files.read("root", "../reference/guide.txt").is_err());
    f.store
        .set_scope("example", "reference", &external, Access::ReadOnly)
        .unwrap();
    assert_eq!(
        f.files.read("reference", "guide.txt").unwrap().content,
        "reference"
    );
    f.store.remove_scope("example", "reference").unwrap();
    assert!(f.files.read("reference", "guide.txt").is_err());
}

#[test]
fn stale_revisions_and_create_collisions_preserve_user_changes() {
    let f = Fixture::new(Access::ReadWrite);
    let initial = f.files.read("root", "src/main.txt").unwrap();
    fs::write(f.project().join("src/main.txt"), "user edit").unwrap();
    assert!(
        f.files
            .write("root", "src/main.txt", "agent edit", &initial.sha256)
            .is_err()
    );
    assert!(
        f.files
            .write("root", "src/main.txt", "agent edit", "new")
            .is_err()
    );
    assert_eq!(
        fs::read_to_string(f.project().join("src/main.txt")).unwrap(),
        "user edit"
    );
    let current = f.files.read("root", "src/main.txt").unwrap();
    let written = f
        .files
        .write("root", "src/main.txt", "reviewed edit", &current.sha256)
        .unwrap();
    assert_eq!(
        written.sha256,
        f.files.read("root", "src/main.txt").unwrap().sha256
    );
}

#[test]
fn registry_persists_and_corruption_never_resets_permissions() {
    let f = Fixture::new(Access::ReadWrite);
    let reopened = WorkspaceStore::open(f.store.directory()).unwrap();
    assert_eq!(reopened.list().unwrap().len(), 1);
    let path = f.store.directory().join("workspaces.json");
    fs::write(&path, "broken registry").unwrap();
    assert!(reopened.list().is_err());
    assert!(f.files.read("root", "src/main.txt").is_err());
    assert_eq!(fs::read_to_string(path).unwrap(), "broken registry");
}

#[test]
fn scope_cannot_expose_its_own_permission_registry() {
    let f = Fixture::new(Access::ReadOnly);
    assert!(
        f.store
            .set_scope("example", "state", f.store.directory(), Access::ReadWrite)
            .is_err()
    );
    assert!(
        f.store
            .set_scope("example", "all", f.temp.path(), Access::ReadWrite)
            .is_err()
    );
}

#[test]
fn unsafe_path_forms_are_rejected() {
    for path in [
        "",
        "../x",
        "src/../../x",
        "/tmp/x",
        "C:/Windows/x",
        "x:secret",
        "NUL",
        "COM1.txt",
        "name.",
        "name ",
        "x\0y",
    ] {
        assert!(validate_relative(path).is_err(), "{path:?}");
    }
    let f = Fixture::new(Access::ReadWrite);
    assert!(
        f.files
            .read("root", f.project().join("src/main.txt").to_str().unwrap())
            .is_err()
    );
}

#[test]
fn oversized_and_binary_files_are_not_returned_as_partial_source() {
    let f = Fixture::new(Access::ReadWrite);
    fs::write(
        f.project().join("large.txt"),
        vec![b'x'; MAX_FILE_BYTES as usize + 1],
    )
    .unwrap();
    fs::write(f.project().join("binary.bin"), [0xff, 0xfe]).unwrap();
    assert!(f.files.read("root", "large.txt").is_err());
    assert!(f.files.read("root", "binary.bin").is_err());
    assert!(
        f.files
            .write(
                "root",
                "large2.txt",
                &"x".repeat(MAX_FILE_BYTES as usize + 1),
                "new"
            )
            .is_err()
    );
    assert!(!f.project().join("large2.txt").exists());
}

#[cfg(windows)]
#[test]
fn windows_directory_junction_cannot_escape_the_scope() {
    let f = Fixture::new(Access::ReadWrite);
    let outside = f.temp.path().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("secret.txt"), "outside").unwrap();
    // Creation only, with fixed argument boundaries; fixture cleanup is Rust's
    // TempDir and never a shell-composed recursive deletion.
    let junction = f.project().join("junction");
    let status = std::process::Command::new("cmd.exe")
        .args(["/d", "/c", "mklink", "/J"])
        .arg(&junction)
        .arg(&outside)
        .output()
        .unwrap();
    assert!(
        status.status.success(),
        "{}",
        String::from_utf8_lossy(&status.stderr)
    );
    assert!(f.files.read("root", "junction/secret.txt").is_err());
    assert!(
        f.files
            .write("root", "junction/new.txt", "escaped", "new")
            .is_err()
    );
    assert!(!outside.join("new.txt").exists());
    // Removing a junction itself is nonrecursive and never follows its target.
    fs::remove_dir(junction).unwrap();
}

#[cfg(unix)]
#[test]
fn symbolic_links_cannot_escape_or_bypass_a_denied_subtree() {
    let f = Fixture::new(Access::ReadWrite);
    std::os::unix::fs::symlink(f.temp.path(), f.project().join("escape")).unwrap();
    std::os::unix::fs::symlink("private", f.project().join("alias")).unwrap();
    f.store
        .set_scope(
            "example",
            "private",
            &f.project().join("private"),
            Access::Deny,
        )
        .unwrap();
    assert!(f.files.read("root", "escape/project/src/main.txt").is_err());
    assert!(f.files.read("root", "alias/secret.txt").is_err());
}
