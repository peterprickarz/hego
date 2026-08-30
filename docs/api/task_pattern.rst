Async Task Pattern
==================

Overview
--------

All HEGo methods that interact with Houdini Engine run on a background worker thread. Instead of blocking GDScript until the call completes, each method returns an :ref:`HEGoTask<class_HEGoTask>` immediately. The task progresses through four states:

.. list-table::
   :widths: 20 80

   * - ``PENDING``
     - Waiting in the queue.
   * - ``RUNNING``
     - Currently executing on the worker thread.
   * - ``COMPLETED``
     - Finished successfully; result is available.
   * - ``FAILED``
     - Encountered an error; see ``get_error_message()``.

This keeps the Godot editor and game loop responsive while Houdini Engine does its work.

Awaiting a Task
---------------

The recommended pattern is a small helper function that polls the task status once per frame:

.. code-block:: gdscript

    func _await_task(task: HEGoTask) -> Variant:
        while task.get_status() < HEGoTask.COMPLETED:
            await get_tree().process_frame
        if task.get_status() == HEGoTask.FAILED:
            push_error("Task failed: " + task.get_error_message())
            return null
        return task.get_result()

Every HEGo demo script includes this helper. Use it like this:

.. code-block:: gdscript

    # Instantiate an HDA
    var asset = HEGoAssetNode.new()
    asset.op_name = "Sop/my_hda"
    await _await_task(asset.instantiate())

    # Set parameters and cook
    await _await_task(asset.set_parm("height", 5.0))
    await _await_task(asset.cook())

    # Fetch output
    var surfaces = await _await_task(asset.fetch_surfaces(my_config))

Error Handling
--------------

When a task fails, ``get_status()`` returns ``HEGoTask.FAILED`` and ``get_error_message()`` contains the
error description. The ``_await_task`` helper shown above returns ``null`` on failure, so callers can
check for that:

.. code-block:: gdscript

    var result = await _await_task(asset.cook())
    if result == null:
        print("Cook failed, check the error log")
        return

Task Queue Inspection
---------------------

:ref:`HEGoAPI<class_HEGoAPI>` exposes methods for inspecting the scheduler state at runtime:

- :ref:`get_current_task()<class_HEGoAPI_method_get_current_task>` -- the task currently executing, or ``null`` if idle.
- :ref:`get_pending_tasks()<class_HEGoAPI_method_get_pending_tasks>` -- tasks waiting in the queue.
- :ref:`get_task_pending_count()<class_HEGoAPI_method_get_task_pending_count>` -- number of pending tasks.
- :ref:`get_completed_task_history()<class_HEGoAPI_method_get_completed_task_history>` -- ring buffer of finished tasks (up to 64).
- :ref:`clear_completed_task_history()<class_HEGoAPI_method_clear_completed_task_history>` -- empties the history buffer.

The HEGo bottom panel includes a **Tasks** column in the HDA tab that displays the live queue and
completed task history using these methods.

Task Ordering
-------------

Tasks are executed in strict submission order on a single worker thread. When you ``await`` each task
sequentially, later tasks naturally wait for earlier ones. If you submit multiple tasks without awaiting
in between, they queue up and run in order:

.. code-block:: gdscript

    # These three tasks queue up and run one after another
    var t1 = asset.set_parm("width", 10)
    var t2 = asset.set_parm("depth", 20)
    var t3 = asset.cook()

    # Wait only for the last one -- the earlier ones will have finished by then
    await _await_task(t3)
