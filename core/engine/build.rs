fn main() {
    // macOS Bluetooth RFCOMM goes through IOBluetooth, which needs Objective-C.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/bluetooth/macos.m")
            .flag("-fobjc-arc")
            .flag("-mmacosx-version-min=12.0")
            .compile("kvj_rfcomm");
        println!("cargo:rustc-link-lib=framework=IOBluetooth");
        println!("cargo:rerun-if-changed=src/bluetooth/macos.m");
    }
}
