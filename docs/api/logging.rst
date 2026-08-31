Logging
=======

Overview
--------

Everything HEGo logs, from C++ and from GDScript alike, goes through one logger:
``HEGoLog``. Each entry carries a level, a category and a timestamp, and ends up in

- an in-memory buffer the **HEGo bottom panel** reads (the Session tab's log view),
- the **Godot output**, if the entry is at or above the output level,
- a **log file**, if file logging is enabled.

Work runs on a background thread (see :doc:`task_pattern`), so entries are recorded
from whichever thread produced them and printed later on the main thread. Nothing in
the logging path calls into Godot from a worker thread.

Levels
------

.. list-table::
   :widths: 20 80

   * - ``TRACE``
     - Per-element detail. Not recorded unless the store level is lowered to it.
   * - ``DEBUG``
     - What HEGo is doing during a cook. Panel and log file only, by default.
   * - ``INFO``
     - Milestones: session started, cook finished, asset selected.
   * - ``WARNING``
     - Something was skipped or guessed; the operation continues.
   * - ``ERROR``
     - The operation failed.

Warnings and errors also go through ``push_warning()`` and ``push_error()``, so they
still show up in Godot's debugger.

Categories
----------

Every entry names the subsystem it came from, which the panel can filter by:
``session``, ``node``, ``cook``, ``input``, ``output``, ``attrib``, ``parm``,
``terrain3d``, ``platform``. Your own scripts may use any string.

Logging from GDScript
---------------------

.. code-block:: gdscript

    var log := HEGoLog.get_singleton()

    log.info("cook", "Cooking %s" % asset_name)
    log.warning("input", "Input %s has no mesh, skipping it." % path)
    log.error("session", "Session failed to start.")

Reading the log back
--------------------

The panel polls the buffer with a cursor, so it only ever appends what is new:

.. code-block:: gdscript

    var log := HEGoLog.get_singleton()
    var entries := log.get_entries_since(cursor, HEGoLog.LEVEL_DEBUG)
    cursor = log.get_cursor()

    for entry in entries:
        print("%s [%s] %s" % [entry["time"], entry["category"], entry["message"]])

``save_to_file(path)`` writes the whole buffer as text, which is what the Session
tab's **Save log...** button uses when you need to attach a log to a bug report.

Project settings
----------------

.. list-table::
   :widths: 40 15 45

   * - ``hego/logging/store_level``
     - ``DEBUG``
     - Lowest level kept in the buffer, and so the most detail the panel can show.
   * - ``hego/logging/output_level``
     - ``INFO``
     - Lowest level printed to the Godot output.
   * - ``hego/logging/enable_file_logging``
     - ``false``
     - Writes every recorded entry to a file as well.
   * - ``hego/logging/log_path``
     - ``user://hego_logs/hego.log``
     - Where those files go. Each run writes its own file, named after this path with
       a timestamp, e.g. ``hego_2026-08-31_14.02.11.log``.
   * - ``hego/logging/max_log_files``
     - ``5``
     - How many of those files to keep. Older ones are deleted; ``0`` keeps them all.

Lowering ``store_level`` to ``TRACE`` costs nothing until you do it: trace messages
are not built at all while the level is above them.
