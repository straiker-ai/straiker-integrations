# Connect Databricks to Straiker: request form

Fill this in before the onboarding session. It covers the decisions to make and the details to have ready.
The Straiker console walks you through creating everything else, step by step, with the exact commands:
**Defend > Add Agent > Agent Platforms > Databricks**.

> **Do not put secrets in this form or in email.** Service principal secrets are pasted only into the Straiker
> console, by your admin, during the session.

---

## 1. What you want Straiker to do

Discover is always on. The others are your choice, and you can change them later in **Settings > Agents**.

| Product | What it does | Your choice |
|---|---|---|
| **Discover** | Lists your Genie spaces, Model Serving agents, Agent Bricks apps, Knowledge Assistants and Unity Catalog MCP services, with owners, permissions and the tables they reach. Reads definitions and permissions only, never conversations. | Always on |
| **Ascend** | Red-team tests the agents you choose, as a test user with a typical user's data access. Genie usage by that user is billed to your workspace. | ☐ Yes ☐ No |
| **Defend: monitor Genie conversations** | Reads every user's Genie questions, answers and generated SQL after each turn, and flags attacks and data leaks. | ☐ Yes ☐ No |
| **Defend: inspect Unity Gateway calls** | Checks model and MCP calls that go through Unity Gateway before they run, and can block them. | ☐ Yes ☐ No |

If you choose either Defend option, confirm that your security or privacy team has approved Straiker processing
this content: ☐ Approved by ____________________

---

## 2. Who needs to be in the session

| Role | Needed for | Name and email |
|---|---|---|
| Workspace admin, in every workspace you connect, with the Databricks CLI installed | Creating the service principals (all products) | |
| Someone who decides what a typical user of each agent can read | Ascend: the test user's permissions | |
| Someone who can create Unity Catalog connections and attach service policies | Defend: Unity Gateway | |
| Straiker console admin | Entering the details and connecting | |

---

## 3. Details to have ready

| Detail | Example | Where to find it | Needed for |
|---|---|---|---|
| Cloud | AWS, Azure or Google Cloud | Your workspace URL's domain: `cloud.databricks.com` (AWS), `azuredatabricks.net` (Azure), `gcp.databricks.com` (Google Cloud). Workspaces on another cloud are a separate connection. | All |
| Workspace URLs | `https://dbc-1a2b3c4d-5e6f.cloud.databricks.com` | Your browser's address bar in each workspace, or **Account console > Workspaces** | All |
| Databricks account ID (optional) | `1a2b3c4d-5e6f-…` | **Account console**, user menu at the top right. Only account admins can open it. Skip it if you can't. | Naming the connection |
| Genie spaces to test | The space ID in the space's URL, after `/genie/rooms/` | Open each Genie space | Ascend |
| Serving endpoints or Agent Bricks apps to test | Endpoint or app name | **Serving** or **Apps** in the workspace | Ascend |
| Models and MCP services to protect | Service name | **Unity Catalog** > the service | Defend: Unity Gateway |

The service principals' application IDs and secrets are created during the session. The console shows the
commands and checks that each secret is pinned to the right scopes.

---

## 4. Before the session

| Check | Done |
|---|---|
| The workspace admin can run `databricks auth login --host <workspace URL>` for each workspace | ☐ |
| If a workspace uses an IP access list, it allows Straiker's addresses (your Straiker contact sends them). Workspaces reachable only through Private Link are not supported yet. | ☐ |
| For Ascend: you have decided what the test user may read. Genie answers with the caller's own permissions, and a space fails every question if the caller can't read one of its tables. | ☐ |
| For Defend on Unity Gateway: you have chosen whether a call is allowed or blocked when Straiker can't answer within Databricks' 5-second limit (blocked by default) | ☐ |

---

## 5. What Straiker can and can't do with what you create

| Credential | Can | Can't |
|---|---|---|
| Discover service principal (a workspace admin, so it sees every Genie space) | Read Genie spaces, agent and app definitions, permissions and Unity Catalog grants. Its secret is pinned to read scopes, and Straiker refuses one that isn't. With Genie monitoring on, also read Genie conversations. | Run SQL, prompt Genie, read table data or secrets, or manage users |
| Ascend service principal (not an admin) | Prompt the Genie spaces, endpoints and apps you grant it, as a typical user | Reach anything its grants don't cover |
| Defend key (only with Defend on Unity Gateway) | Authenticate Databricks' policy calls to Straiker | Call Databricks at all |

Questions: your Straiker contact.
