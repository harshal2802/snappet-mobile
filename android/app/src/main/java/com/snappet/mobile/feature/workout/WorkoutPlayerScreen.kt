// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Add a snackbar to celebrate the completion of a workout
fun onComplete() {
    val snackbar = Snackbar.make(binding.root, "Workout complete!", Snackbar.LENGTH_SHORT)
    snackbar.show()
    // Add haptic feedback
    Motion.handleHapticFeedback(context)
}