//! Test binary for diagnosing RocksDB issues on macOS
use oxigraph::store::Store;
use std::panic;
use std::path::Path;

fn main() {
    let test_path = "/tmp/xm-rocksdb-test";

    println!("=== Oxigraph Store Test ===");
    println!("Platform: {}", std::env::consts::OS);
    println!("Arch: {}", std::env::consts::ARCH);
    println!("Test path: {}", test_path);
    println!();

    // Clean up any existing test database
    if Path::new(test_path).exists() {
        println!("Removing existing test database...");
        std::fs::remove_dir_all(test_path).expect("Failed to remove test dir");
    }

    // Test 1: In-memory store
    println!("Test 1: Creating in-memory store...");
    match Store::new() {
        Ok(store) => {
            println!("  SUCCESS: In-memory store created");
            println!("  Is empty: {:?}", store.is_empty());
            drop(store);
            println!("  Store closed");
        }
        Err(e) => {
            println!("  FAILED: {:?}", e);
        }
    }
    println!();

    // Test 2: Persistent store with panic catch
    println!("Test 2: Creating persistent store with panic handler...");

    // Set up panic hook to get better error info
    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|info| {
        println!("  PANIC CAUGHT:");
        if let Some(location) = info.location() {
            println!("    File: {}", location.file());
            println!("    Line: {}", location.line());
            println!("    Column: {}", location.column());
        }
        if let Some(msg) = info.payload().downcast_ref::<&str>() {
            println!("    Message: {}", msg);
        } else if let Some(msg) = info.payload().downcast_ref::<String>() {
            println!("    Message: {}", msg);
        }
    }));

    let result = panic::catch_unwind(|| {
        Store::open(test_path)
    });

    panic::set_hook(prev_hook);

    match result {
        Ok(Ok(store)) => {
            println!("  SUCCESS: Persistent store created!");
            println!("  Is empty: {:?}", store.is_empty());

            // Try a simple insert
            println!("  Attempting insert...");
            let insert_result = store.update(
                "INSERT DATA { <http://example.org/s> <http://example.org/p> \"test\" }"
            );
            match insert_result {
                Ok(_) => println!("  Insert SUCCESS"),
                Err(e) => println!("  Insert FAILED: {:?}", e),
            }

            drop(store);
            println!("  Store closed");
        }
        Ok(Err(e)) => {
            println!("  FAILED with error: {:?}", e);
        }
        Err(e) => {
            println!("  PANIC occurred during store creation");
            if let Some(msg) = e.downcast_ref::<&str>() {
                println!("  Panic message: {}", msg);
            } else if let Some(msg) = e.downcast_ref::<String>() {
                println!("  Panic message: {}", msg);
            }
        }
    }

    // Clean up
    if Path::new(test_path).exists() {
        println!("\nCleaning up test database...");
        let _ = std::fs::remove_dir_all(test_path);
    }

    println!("\n=== Test Complete ===");
}
