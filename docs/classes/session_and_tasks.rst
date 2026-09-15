Session, tasks and logging
==========================

The session itself, the queue every Houdini call goes through, and where messages come out. See :doc:`/api/task_pattern` and :doc:`/api/logging`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoAPI<class_HEGoAPI>`
     - Singleton entry point for HEGo session management, task scheduling, and HDA discovery.
   * - :ref:`HEGoTask<class_HEGoTask>`
     - Represents an asynchronous task submitted to the HEGo task scheduler.
   * - :ref:`HEGoLog<class_HEGoLog>`
     - HEGo's logger, shared by the C++ side and GDScript.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegoapi
   class_hegotask
   class_hegolog
