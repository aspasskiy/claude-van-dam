import Foundation
import IOKit.pwr_mgt
import SwapCore

/// "Keep awake": holds a PreventUserIdleSystemSleep assertion (what
/// `caffeinate -i` does). The display still sleeps on its normal schedule;
/// closing the lid still sleeps the Mac.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0

    var isActive: Bool { assertion != 0 }

    func set(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "\(AppInfo.name) keep awake (display may sleep)" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    deinit { set(false) }
}
