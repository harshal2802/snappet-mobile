package com.snappet.mobile.widget

import androidx.glance.action.ActionParameters

/** Action-parameter key carrying a habit id to the headless check-off callback. */
val HabitIdKey = ActionParameters.Key<String>("habitId")

/** Action-parameter key carrying a module id to MainActivity when a widget opens the app. */
val moduleKey = ActionParameters.Key<String>(com.snappet.mobile.MainActivity.EXTRA_MODULE)
