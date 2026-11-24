use std::fs;

fn read_trim(path: &str) -> String {
    fs::read_to_string(path)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "absent".to_string())
}

/// The four machine readings that show whether the workload runs in a sandbox.
/// A source that is missing or unreadable reads `absent`.
pub fn collect() -> [(&'static str, String); 4] {
    let uptime = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(str::to_string))
        .unwrap_or_else(|| "absent".to_string());
    let disks = fs::read_dir("/sys/block")
        .ok()
        .map(|entries| {
            let mut names: Vec<String> = entries
                .filter_map(Result::ok)
                .filter_map(|e| e.file_name().into_string().ok())
                .collect();
            names.sort();
            names.join(",")
        })
        .unwrap_or_else(|| "absent".to_string());
    [
        ("kernel", read_trim("/proc/sys/kernel/osrelease")),
        ("uptime_s", uptime),
        ("disks", disks),
        ("dmi_product", read_trim("/sys/class/dmi/id/product_name")),
    ]
}

fn format_readings(r: &[(&str, String)]) -> String {
    r.iter()
        .map(|(k, v)| format!("reading {k}={v}\n"))
        .collect()
}

/// Print the readings at startup (readable in debug mode; production denies logs).
pub fn log_readings() {
    print!("{}", format_readings(&collect()));
}

#[cfg(test)]
mod tests {
    use super::{collect, format_readings};

    #[test]
    fn readings_format() {
        let r = [
            ("kernel", "5.10.0".to_string()),
            ("uptime_s", "123.4".to_string()),
            ("disks", "nvme0n1,sda".to_string()),
            ("dmi_product", "t3.micro".to_string()),
        ];
        assert_eq!(
            format_readings(&r),
            "reading kernel=5.10.0\nreading uptime_s=123.4\nreading disks=nvme0n1,sda\nreading dmi_product=t3.micro\n"
        );
    }

    #[test]
    fn collect_has_four_keys_in_order() {
        let keys: Vec<&str> = collect().iter().map(|(k, _)| *k).collect();
        assert_eq!(keys, ["kernel", "uptime_s", "disks", "dmi_product"]);
    }
}
