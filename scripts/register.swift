#!/usr/bin/env swift
import Carbon
import Foundation

func sourceIdentifier(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

if CommandLine.arguments == [CommandLine.arguments[0], "--current"] {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    if let identifier = sourceIdentifier(source) {
        print(identifier)
        exit(0)
    }
    exit(1)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--select" {
    let requestedIdentifier = CommandLine.arguments[2]
    let candidates = TISCreateInputSourceList(nil, true).takeRetainedValue() as NSArray
    for case let source as TISInputSource in candidates
    where sourceIdentifier(source) == requestedIdentifier {
        exit(TISSelectInputSource(source) == noErr ? 0 : 1)
    }
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data(
            "Usage: register.swift /path/to/BiLing.app | --current | --select INPUT_SOURCE_ID\n"
                .utf8
        )
    )
    exit(64)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let status = TISRegisterInputSource(bundleURL as CFURL)
guard status == noErr else {
    FileHandle.standardError.write(Data("TISRegisterInputSource failed: \(status)\n".utf8))
    exit(1)
}

guard let unmanaged = TISCreateInputSourceList(nil, true),
      let sources = unmanaged.takeRetainedValue() as? [TISInputSource] else {
    print("Registered 笔灵; macOS will expose it after the input-source cache refreshes.")
    exit(0)
}

var enabledCount = 0
var checkedMode = false
for source in sources {
    guard let identifier = sourceIdentifier(source) else { continue }
    guard identifier == "com.biling.inputmethod.BiLing"
        || identifier.hasPrefix("com.biling.inputmethod.BiLing.") else { continue }
    if identifier == "com.biling.inputmethod.BiLing.Hans" {
        checkedMode = true
        guard let asciiPointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceIsASCIICapable
        ) else {
            FileHandle.standardError.write(
                Data("BiLing input mode has no ASCII-capability metadata.\n".utf8)
            )
            exit(1)
        }
        let asciiValue = Unmanaged<AnyObject>
            .fromOpaque(asciiPointer)
            .takeUnretainedValue() as? NSNumber
        guard asciiValue?.boolValue == false else {
            FileHandle.standardError.write(
                Data(
                    "BiLing was incorrectly registered as ASCII-capable; "
                        .appending("the 中/英 key would route to the wrong source.\n")
                        .utf8
                )
            )
            exit(1)
        }
    }
    if TISEnableInputSource(source) == noErr {
        enabledCount += 1
    }
}
guard checkedMode else {
    FileHandle.standardError.write(
        Data("macOS did not expose the BiLing Simplified Chinese mode.\n".utf8)
    )
    exit(1)
}
guard enabledCount > 0 else {
    print("Registered 笔灵; macOS will expose it after the input-source cache refreshes.")
    exit(0)
}
print("Registered and enabled 笔灵 as a non-Latin Simplified Chinese source (\(enabledCount) sources).")
