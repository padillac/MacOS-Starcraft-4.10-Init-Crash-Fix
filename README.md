# sc2fix: StarCraft II 4.10 on macOS

`sc2fix.sh` fixes the StarCraft II 4.10 build (`Base75689`, the version AI Arena bots run on) crashing on startup on macOS. It changes only that build's folder on your Mac. Your bot code is untouched, so ladder games are unaffected.

## Symptom

The 4.10 binary aborts a few seconds after launch, before it opens the API port:

```
libc++abi: __cxa_guard_acquire detected recursive initialization: do you have a function-local static variable whose initialization depends on that function?
```

The crash report shows `EXC_CRASH (SIGABRT)`, raised by SC2 itself, with no backtrace.

## Root cause

A backtrace taken inside the crashing process shows a re-entrancy bug in SC2's own startup code. It happens before `main`, while dyld is running SC2's C++ static initializers:

1. A static initializer asks for SC2's global allocator. The allocator is created lazily inside a function-local `static`, so the C++ runtime marks that static as "initialization in progress".
2. While setting up the allocator, SC2's Mac code checks the GPU against a blacklist by compiling an `NSRegularExpression` (first pattern: `.*geforce.*7300.*`).
3. Foundation hands the regex to ICU's `uregex_open`, which allocates with global `operator new`.
4. SC2 replaces global `operator new` with its own allocator, so that allocation comes back into SC2 and asks for the allocator again.
5. The allocator's static is still mid-initialization on the same thread. `libc++abi` detects the recursion and calls `abort()`.

The regex check is Mac-only (`NSRegularExpression` is Apple's Foundation framework), which is why the Windows client doesn't crash.

**Still unknown:** what changed on Oct 7, 2026. These were ruled out as the trigger: the system clock, environment variables, preferences, network access, Battle.net running, the macOS locale, macOS updates, and SC2's bundled ICU libraries (unchanged 2013 builds). The patch that landed that week installed 5.0.17 (`Base98310`). Launched directly in API mode on a Mac, that build exits with status 1 and prints nothing, which hasn't been investigated.

## How the fix works

**`sc2fix.dylib`** is injected into SC2 with `DYLD_INSERT_LIBRARIES`. Through dyld interposing it:

- wraps `__cxa_guard_acquire`, `__cxa_guard_release` and `__cxa_guard_abort` to track, per thread, which function-local statics are mid-initialization;
- while any of them is, makes `uregex_open` fail cleanly (`U_MEMORY_ALLOCATION_ERROR`) instead of allocating.

Foundation then returns `nil` for that regex. Objective-C calls on `nil` return 0, so each blacklist check reads as "no match", which is the correct answer for Apple Silicon GPUs. Regexes compiled at any other time are unaffected. If a recursive initialization still happens, the dylib prints the call stack before the abort.

**The wrapper** gets the dylib loaded however SC2 is launched. `install` renames `Versions/Base75689/SC2.app/Contents/MacOS/SC2` to `SC2.real`, then puts two things in that folder:

- `sc2fix.dylib`, compiled from source embedded in the script;
- a small bash wrapper at the original `SC2` path, which sets `DYLD_INSERT_LIBRARIES` and runs `exec -a "$0" SC2.real "$@"`.

That `exec` makes SC2 replace the wrapper in the same process, with the same `argv[0]` and arguments. So python-sc2 and sc2-kiss launch the wrapper unmodified and can still terminate the game. `DYLD_INSERT_LIBRARIES` survives because the wrapper sets it after bash starts, and `SC2.real` doesn't use Apple's hardened runtime, so it accepts injected libraries.

## Usage

Requirements: macOS with Rosetta, and the Xcode Command Line Tools (`xcode-select --install`).

```sh
chmod +x sc2fix.sh
./sc2fix.sh install     # build the dylib and install the wrapper (safe to re-run)
./sc2fix.sh test        # start 4.10 in API mode; PASS if it starts listening
./sc2fix.sh status      # installed / not installed / reverted by Battle.net
./sc2fix.sh uninstall   # put the original binary back
```

- If the `MacOS` folder isn't writable, run with `sudo`.
- `SC2PATH` sets the StarCraft II folder (default `/Applications/StarCraft II`). `SC2FIX_BASE` sets the version folder to patch (default `Base75689`).

**Running bots:** pass `--sc2-version 4.10` to `run.py`. Without it, python-sc2 launches the newest `Versions/Base*` folder (`latest_executeble` in `sc2/paths.py`), not 4.10.

```sh
python run.py --sc2-version 4.10 --map <MapName>
```

**After a Battle.net update or Scan and Repair:** the original binary may come back. `status` will say `reverted`; run `install` again.

**The binary will also be reverted anytime you use SC2Switcher to invoke that engine version** i.e., opening up a replay using that engine version will cause it to be redownloaded and overwrite the shell wrapper.
