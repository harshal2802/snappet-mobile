// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Add a snackbar to celebrate a milestone
fun onMilestone() {
    val snackbar = Snackbar.make(binding.root, "Milestone reached!", Snackbar.LENGTH_SHORT)
    snackbar.show()
    // Add haptic feedback
    Motion.handleHapticFeedback(context)
}