// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Add a snackbar to celebrate the completion of a pomodoro
fun onComplete() {
    val snackbar = Snackbar.make(binding.root, "Pomodoro complete!", Snackbar.LENGTH_SHORT)
    snackbar.show()
    // Add haptic feedback
    Motion.handleHapticFeedback(context)
}