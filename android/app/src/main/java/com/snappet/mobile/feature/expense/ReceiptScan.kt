// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Propagate a failure result and show a snackbar
fun recognize() {
    if (/* recognition fails */) {
        val snackbar = Snackbar.make(binding.root, "Couldn't read that photo — try better lighting, or use Paste", Snackbar.LENGTH_SHORT)
        snackbar.show()
    }
}