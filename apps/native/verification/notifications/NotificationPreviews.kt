package org.simpleagentmanager.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.android.tools.screenshot.PreviewTest
import org.simpleagentmanager.core.RequestState

@PreviewTest
@Preview(widthDp = 900, heightDp = 850, showBackground = true, name = "Tablet")
@Preview(widthDp = 393, heightDp = 850, showBackground = true)
@Composable
fun ActionableInboxPreview() {
    MaterialTheme {
        Surface {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Notifications", style = MaterialTheme.typography.headlineMedium)
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text("Agent needs your input", style = MaterialTheme.typography.titleMedium)
                        RequestContent(RequestState("", "Which deployment should I use for the release?", listOf("Staging first, then production after verification", "Production"), "", null, false, false, true, null, false, null), false, false, "", {}, null, {}, { _, _ -> }, {})
                        TextButton({}) { Text("Open conversation") }
                    }
                }
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text("Agent needs your input", style = MaterialTheme.typography.titleMedium)
                        RequestContent(RequestState("", "What should the release notes mention?", emptyList(), "", null, false, false, true, null, false, null), false, false, "Include the new notification inbox.", {}, null, {}, { _, _ -> }, {})
                    }
                }
                Spacer(Modifier.weight(1f))
                MainTabs(true, {}, {})
            }
        }
    }
}
@PreviewTest
@Preview(widthDp = 900, heightDp = 1100, showBackground = true, name = "Tablet")
@Preview(widthDp = 393, heightDp = 1100, showBackground = true)
@Composable
fun SecretAndApprovalPreview() {
    MaterialTheme {
        Surface {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Notifications", style = MaterialTheme.typography.headlineMedium)
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        RequestContent(RequestState("DEPLOY_TOKEN", "I need a token to deploy the app.", emptyList(), "pending", null, false, false, true, "v1", false, null), true, false, "example-only", {}, null, {}, { _, _ -> }, {})
                    }
                }
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        RequestContent(RequestState("delete_node · node node1", "This node is unused and has no active sessions.", listOf("approve", "deny"), "pending", null, true, false, true, null, false, null), false, true, "", {}, null, {}, { _, _ -> }, {})
                    }
                }
            }
        }
    }
}
