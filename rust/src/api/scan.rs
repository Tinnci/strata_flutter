use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct VolumeSummary {
    pub name: String,
    pub mount_point: String,
    pub total_bytes: u64,
    pub available_bytes: u64,
    pub is_system_drive: bool,
}

#[derive(Debug, Clone)]
pub struct ScanNodeData {
    pub id: u32,
    pub parent: Option<u32>,
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    pub is_small_group: bool,
    pub item_count: u32,
    pub children: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct ScanResultData {
    pub root_path: String,
    pub entry_count: u64,
    pub total_scanned_bytes: u64,
    pub nodes: Vec<ScanNodeData>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn list_volumes() -> Vec<VolumeSummary> {
    crate::platform::list_volumes()
}

pub fn scan_directory(root_path: String, prune_below_bytes: u64) -> Result<ScanResultData, String> {
    let root = Path::new(&root_path);
    if !root.exists() {
        return Err(format!("Path does not exist: {root_path}"));
    }

    let mut nodes: Vec<ScanNodeData> = Vec::with_capacity(4096);
    let mut entry_count: u64 = 0;

    let root_name = root
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| root_path.clone());

    nodes.push(ScanNodeData {
        id: 0,
        parent: None,
        name: root_name,
        size: 0,
        is_dir: true,
        is_small_group: false,
        item_count: 1,
        children: Vec::new(),
    });

    crate::platform::scan_recursive(
        root,
        0,
        prune_below_bytes,
        &mut nodes,
        &mut entry_count,
    );

    // Compute sizes bottom-up and sort children descending by size.
    for id in (0..nodes.len()).rev() {
        if nodes[id].is_dir {
            let mut sum = nodes[id].size;
            for &child_id in &nodes[id].children {
                sum = sum.saturating_add(nodes[child_id as usize].size);
            }
            nodes[id].size = sum;
        }
    }

    for id in 0..nodes.len() {
        if nodes[id].children.len() > 1 {
            let mut children = std::mem::take(&mut nodes[id].children);
            children.sort_by(|&a, &b| nodes[b as usize].size.cmp(&nodes[a as usize].size));
            nodes[id].children = children;
        }
    }

    let total_scanned_bytes = nodes[0].size;
    Ok(ScanResultData {
        root_path,
        entry_count,
        total_scanned_bytes,
        nodes,
    })
}

pub fn reveal_in_explorer(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        Command::new("explorer")
            .arg(format!("/select,{path}"))
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .args(["-R", &path])
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let target = Path::new(&path)
            .parent()
            .unwrap_or_else(|| Path::new(&path))
            .to_string_lossy()
            .into_owned();
        Command::new("xdg-open")
            .arg(target)
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
}

pub fn move_to_trash(path: String) -> Result<(), String> {
    crate::platform::move_to_trash(&path)
}
