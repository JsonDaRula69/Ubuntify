COMPREHENSIVE AUTOMATED CODE REVIEW AND TESTING PROTOCOL
Execute a systematic, multi-phase review and testing cycle. Do not stop at static analysis. Each phase must be completed before moving to the next. Found bugs must be fixed, then ALL tests re-run from the beginning.

PHASE 0: CODEBASE ARCHITECTURE MODEL
Perform this phase FIRST. Its findings feed into and expand the scope of all subsequent phases.
0.1 Sourcing Tree and Initialization Order
Map the complete sourcing tree: which script sources which, in what order
Trace the entry point initialization sequence step by step from first line to main()
Document which modules are loaded before others and why that order matters
Identify any modules that are conditionally sourced and under what conditions
0.2 Variable Namespace Collision Map
List ALL `readonly` and `declare -r` declarations across every file
List ALL `export`'d variables and trace which modules consume them
Identify ALL shared variable names across modules (SCRIPT_DIR, LIB_DIR, ESP_NAME, etc.)
For each shared variable: document which module owns it, which modules read it, and whether any module attempts to reassign it
Flag: any library that re-assigns a variable already declared `readonly` in a parent scope
0.3 Function Namespace Map
List ALL function definitions across every .sh file
Identify any function name collisions across modules
Identify any function that shadows a system command
0.4 Guard Variable Audit
Check every lib/*.sh for a guard variable (e.g., _COLORS_SH_SOURCED)
List which modules have guards and which don't
Determine if any module can be double-sourced and what would break
0.5 Architecture Diagram
Produce a dependency diagram: main script → libs → sub-libs
Mark each edge with what is consumed (variables, functions)
Highlight circular dependencies or fragile ordering assumptions

PHASE 1: STATIC CODE ANALYSIS
Before running static analysis, create a .shellcheckrc file:
  source-path=lib/
  # Document intentional patterns that warrant ignores
All findings from this phase must be classified by severity:
  P0 (Fatal): Script won't start, crashes immediately, data loss risk
  P1 (Critical): Core feature broken, wrong behavior, silent data corruption
  P2 (Major): Error path mishandled, missing validation, incorrect fallback
  P3 (Minor): Style, formatting, documentation gaps, non-idiomatic patterns

1.1 Syntax and Structure Validation
Run syntax checks on ALL shell scripts: bash -n for each .sh file
Run ShellCheck with full severity coverage: shellcheck -x --severity=warning
Run formatting validation: shfmt -i 2 -ci -bn -d
Document EVERY warning, error, and suggestion — do not filter
Classify each finding as P0/P1/P2/P3
1.2 Variable and Scope Analysis
Audit ALL variable declarations (local, readonly, declare, export)
Identify duplicate declarations or reassignments of the same variable name
Trace variable scope throughout the codebase — especially across source boundaries
Check for variable naming conflicts between scripts/libraries (using Phase 0.2 map)
Verify all required environment variables are documented
Identify any variable used before it is set (with set -u active)
Check for variables that should be local but aren't
1.3 Dependency Graph Mapping
Map all function calls and their dependencies
Identify all external command dependencies
Check that all sourced files exist and are valid
Document the execution order and call hierarchy
Identify circular dependencies
Verify that every function referenced in a case/esac or callback actually exists
1.4 Control Flow Analysis
Trace all execution paths including error paths
Identify unreachable code
Check all exit paths have proper cleanup
Verify all conditionals cover their intended cases
Check loop termination conditions
Trace what happens when `set -e` encounters a failing command in a pipeline, subshell, or conditional
Identify any `|| true` or `|| :` that might be swallowing real errors

PHASE 2: FUNCTIONAL BEHAVIOR TESTING
2.1 Mode and Flag Testing
Test EVERY command-line flag individually
Test all flag combinations (pairwise testing)
Verify help/version flags work correctly
Test invalid flag handling and error messages
Test all environment variable overrides
Verify flags that are documented in --help actually exist in the argument parser
Verify the argument parser handles --flag=value syntax for all applicable flags
2.2 Execution Mode Testing
Test dry-run/simulation modes for EVERY deployment method
Verify dry-run produces ZERO side effects — audit every code path to ensure no destructive command executes when DRY_RUN=1
Verify dry-run exits with code $E_DRY_RUN_OK (11)
Test verbose/quiet modes
Test agent mode with --agent flag
Test --agent --yes confirms destructive operations automatically
Test --agent WITHOUT --yes denies destructive operations
Test --json flag produces valid JSON output
2.3 Normal Execution Path Testing
Execute all primary workflows that can be safely executed
Test with valid inputs across boundary conditions
Test file operations (create, read, modify, delete) where safe
Test network operations (if applicable)
Test process execution and subprocess handling
2.4 Error Path Testing
Test with missing required arguments
Test with invalid input types
Test with missing/invalid file paths
Test with insufficient permissions
Test resource exhaustion scenarios
Test network failures and timeouts
Test dependency failures (missing commands, wrong versions)
Verify error messages are clear and actionable
Verify exit codes match documented values

PHASE 3: INTEGRATION AND SYSTEM TESTING
3.1 Script Interaction Testing
Test scripts calling other scripts
Test scripts sourcing libraries — verify sourcing order matches Phase 0.1
Test scripts using shared resources
Test scripts in different working directories
Test scripts with relative vs absolute paths
3.2 Environment Testing
Test with minimal environment (empty ENV)
Test with missing dependencies
Test with conflicting configurations
Test with different shell versions (bash 3.2 vs 5.x)
Test on all target platforms (macOS for build, Linux for remote)
3.3 Concurrency and State Testing
Test scripts running simultaneously
Test scripts modifying shared state
Test idempotency (run multiple times)
Test cleanup on interrupt (Ctrl-C, SIGTERM)
Test cleanup on error exit
Verify trap handlers execute correctly in all exit scenarios
3.4 Resource Management
Verify all temporary files are cleaned up
Verify all file descriptors are closed
Verify all background processes are terminated
Verify all locks are released
Verify proper handling of large files/datasets

PHASE 4: BEST PRACTICES AND PATTERNS
4.1 Error Handling Audit
Verify set -Eeuo pipefail usage (or equivalent)
Check for proper error trapping: trap 'error_handler' ERR
Verify all external commands have error handling
Check for proper exit codes
Verify error messages are clear and actionable
4.2 Safety and Security Review
Check for proper input validation and sanitization
Verify no unsafe use of eval or source with user input
Check for proper quoting of ALL variable expansions
Verify safe handling of temporary files/directories
Check for proper permission handling
Verify no hardcoded credentials or secrets
4.3 Portability Review
Check for bashisms if POSIX compatibility required
Verify GNU vs BSD command compatibility (macOS uses BSD, Ubuntu uses GNU)
Check for hardcoded paths
Verify proper shebang lines
Check for platform-specific code paths
4.4 Documentation Review
Verify all functions have usage documentation
Verify all scripts have help text
Verify all dependencies are documented
Verify all environment variables are documented
Verify all error codes are documented

PHASE 5: EXECUTION AND VALIDATION
SAFETY BOUNDARIES — classify every testable unit before execution:
SAFE (run on development Mac): syntax checks, --help, --dry-run, read-only operations, Node.js monitor
DESTRUCTIVE (only via --dry-run flag or in VirtualBox): disk partitioning, APFS resize, format, dd, USB writes
REMOTE-ONLY (requires ssh access to target): all lib/remote.sh operations, manage mode
VM-REQUIRED: deploy_vm_test, VirtualBox operations

5.1 Actual Execution Testing
Execute scripts within their safety boundary classification
Execute scripts with production-like data where safe
Monitor resource usage (CPU, memory, I/O)
Verify execution completes within expected time bounds
5.2 Failure Mode Testing
Inject failures at critical points
Test recovery mechanisms
Verify rollback works correctly
Test cleanup on failure
Verify logs/reports are accurate after failure
5.3 Stress and Boundary Testing
Test with minimum/maximum input sizes
Test with empty inputs
Test with malformed inputs
Test with special characters in inputs

ITERATIVE FIX AND TEST CYCLE
Process findings in severity order: P0 first, then P1, then P2, then P3.
Within each severity level, fix bugs one at a time.

For each bug:
1. Fix Implementation
   Document the bug in detail
   Identify root cause
   Implement minimal, focused fix
   Add comments explaining the fix if non-obvious

2. Full Regression Testing
   After ANY code change, re-run ALL phases from the beginning:
   Phase 0: Re-verify architecture model is still accurate
   Phase 1: Re-run all static analysis
   Phase 2: Re-run all functional tests
   Phase 3: Re-run all integration tests
   Phase 4: Re-run all best practices checks
   Phase 5: Re-run all execution tests
   Document any NEW findings introduced by the fix

3. Version Control
   When all phases pass for a fix:
   Query current version: git tag --list 'v0.2.*' | sort -V | tail -1
   Stage changes: git add -A
   Commit with descriptive message:
     fix: [brief description]

     - Fixed [specific issue]
     - Root cause: [explanation]
     - Verified by: [phases re-run]

   Tag with next version: git tag -a v0.2.X -m "fix: [brief description]"
   Push: git push && git push --tags

Continue Until
ALL phases pass with zero P0, P1, P2 findings
P3 findings are documented (fix if trivial, document if not)
ShellCheck reports zero errors (warnings acceptable if covered by .shellcheckrc)
Scripts execute correctly in all tested environments within safety boundaries
Documentation reflects current reality

REPORTING REQUIREMENTS
After each phase, provide:

Findings: Complete list of all issues discovered
Severity: P0/P1/P2/P3 classification for each finding
Impact: What breaks and for whom
Evidence: Logs, output, or reproduction steps
Root Cause: Why this happens (especially for cross-module issues found via Phase 0)
Fix Applied: What was changed and why
Verification: How the fix was validated and which phases were re-run
Next Steps: What needs to be checked next

FINAL CHECKLIST
Before completion, verify:

 All scripts pass bash -n syntax check
 All scripts pass ShellCheck with zero errors
 All command-line flags tested individually and in combination
 All execution modes tested (dry-run, verbose, agent, json)
 All readonly/export variable collisions resolved
 All guard variables present and effective
 All lib modules source-compatible with main script's declarations
 Dry-run mode produces zero side effects for all deployment methods
 All error paths tested with proper messages and exit codes
 All dependencies documented and verified
 All temporary resources properly cleaned up
 All exit codes match documentation
 All integration scenarios tested
 Architecture model (Phase 0) still accurate after all fixes
 All commits properly tagged on v0.2.* sequence and pushed