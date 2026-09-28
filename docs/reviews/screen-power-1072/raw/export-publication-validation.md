# Export publication failure validation

Author validation of `hardware/kicad/screen_power/export.py`; independent
review and final CAD package generation remain separate.

Publication first copies the completed export into a staging directory on the
destination filesystem. Only after that copy succeeds does it rename the
previous package to a backup and install the prepared replacement. A failed
installation restores the backup. If restoration also fails, the exception
identifies the retained backup and cleanup leaves it available for recovery.
The previous package is removed only after installation succeeds.

A disposable filesystem fixture called the real `publish_package` helper.
Only copying and renaming were intercepted to inject failures. No CAD command
ran and no real manufacturing package was changed.

| Case | Observed result |
| --- | --- |
| First publication | Complete new package installed; staging removed. |
| Successful replacement | Complete new package installed; previous package and staging removed. |
| Copy fails after writing a partial file | Failure raised; original destination sentinel unchanged; partial staging removed. |
| Renaming the previous destination fails | Failure raised; original destination sentinel unchanged; staging removed. |
| Installing the prepared replacement fails | Failure raised; previous package restored with its sentinel unchanged; staging removed. |
| Installation and rollback both fail | Failure raised with recovery location; complete previous package retained in the backup directory. |

All six cases passed. Python compilation and Git whitespace checks also passed.
These checks cover caught filesystem failures, not process termination between
the two rename operations or concurrent exporters targeting the same directory.
