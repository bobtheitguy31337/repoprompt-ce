enum SchemaV6 {
    static let version = 6
    static let digest = "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit"

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS agent_model_profiles(scope_id TEXT PRIMARY KEY,project_id TEXT,profile_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS subagent_permission_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS context_builder_settings(scope_id TEXT PRIMARY KEY,project_id TEXT,settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS mcp_model_presets(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),presets_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS advanced_server_settings(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),settings_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS project_selection_presets(project_id TEXT PRIMARY KEY,presets_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL,FOREIGN KEY(project_id) REFERENCES projects(project_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS settings_audit(audit_id TEXT PRIMARY KEY,domain TEXT NOT NULL,scope_id TEXT NOT NULL,prior_revision INTEGER NOT NULL,new_revision INTEGER NOT NULL,operation TEXT NOT NULL,actor_id TEXT NOT NULL,actor_label TEXT NOT NULL,channel TEXT NOT NULL,payload_digest TEXT NOT NULL,created_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workflow_repository_state(fixed_id INTEGER PRIMARY KEY CHECK(fixed_id=1),collection_revision INTEGER NOT NULL,include_session_cleanup_guidance INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workflow_repository_metadata(workflow_id TEXT PRIMARY KEY REFERENCES workflows(workflow_id) ON DELETE CASCADE,visible INTEGER NOT NULL,featured_order INTEGER,row_revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_direct_configurations(provider_id TEXT PRIMARY KEY,configuration_json TEXT NOT NULL,revision INTEGER NOT NULL,updated_at REAL NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_model_catalogs(provider_id TEXT PRIMARY KEY,catalog_json TEXT NOT NULL,revision INTEGER NOT NULL,refreshed_at REAL NOT NULL)",
        "CREATE INDEX IF NOT EXISTS settings_audit_domain_scope_time ON settings_audit(domain,scope_id,created_at)",
        "CREATE UNIQUE INDEX IF NOT EXISTS workflow_repository_featured_order ON workflow_repository_metadata(featured_order) WHERE featured_order IS NOT NULL"
    ]
}
