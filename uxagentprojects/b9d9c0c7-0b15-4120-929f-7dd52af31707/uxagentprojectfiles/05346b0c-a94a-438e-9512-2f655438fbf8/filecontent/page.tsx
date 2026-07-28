import React, { useState, useEffect, useMemo } from "react";
import {
    Button,
    Text,
    DataGrid,
    DataGridHeader,
    DataGridBody,
    DataGridRow,
    DataGridCell,
    DataGridHeaderCell,
    TableCellLayout,
    createTableColumn,
    Input,
} from "@fluentui/react-components";
import type {
    GeneratedComponentProps,
    workspace,
    ReadableTableRow,
    WritableTableRow,
    QueryTableOptions,
} from "./RuntimeTypes";

// --- Localization Setup ---
const langMap: Record<number, { code: string; name: string; isRtl: boolean }> = {
    1033: { code: "en-US", name: "English (United States)", isRtl: false },
};
const translations: Record<string, Record<string, string>> = {
    "en-US": {
        appTitle: "Fabric Workspace Administration",
        workspaceListTitle: "My Workspaces",
        filterPlaceholder: "Filter workspaces...",
        workspaceName: "Workspace Name",
        primaryOwner: "Primary Owner",
        secondaryOwner: "Secondary Owner",
        editWorkspaceTitle: "Edit Workspace",
        renameLabel: "Rename workspace",
        save: "Save",
        cancel: "Cancel",
        noWorkspaces: "No workspaces found.",
        loading: "Loading...",
        selectWorkspace: "Select a workspace to edit.",
        renameSuccess: "Workspace renamed successfully.",
        renameError: "Failed to rename workspace.",
        addWorkspaceTitle: "Add Workspace",
        addWorkspace: "Add Workspace",
        addWorkspaceSuccess: "Workspace added successfully.",
        addWorkspaceError: "Failed to add workspace.",
        workspaceNamePlaceholder: "Enter workspace name",
        primaryOwnerPlaceholder: "Enter primary owner",
        secondaryOwnerPlaceholder: "Enter secondary owner",
        helpTitle: "Workspace Administration Help",
        helpConnected: "This app is connected to Dataverse and displays workspaces where you are listed as a primary or secondary owner.",
        helpManualAdd: "You can manually add or edit workspace records in Dataverse using Power Apps or Dataverse admin tools.",
        helpSecurity: "Workspaces are filtered by your Dataverse user ID, not your email address. If you want to filter by email, please ensure the workspace table stores owner emails.",
        helpCurrentEmail: "Your current email address:",
    },
};

// --- User Settings for Formatting ---
function useUserSettings(dataApi: any) {
    const [userSettings, setUserSettings] = useState<any>(null);
    useEffect(() => {
        const fetchUserSettings = async () => {
            const currentUserId =
                (typeof Xrm !== "undefined" &&
                    Xrm.Utility?.getGlobalContext()?.userSettings?.userId)
                    ?.replace("{", "")
                    .replace("}", "");
            if (!currentUserId) return;
            const settings = await dataApi.retrieveRow("usersettings", {
                id: currentUserId,
                select: [
                    "uilanguageid",
                    "localeid",
                    "decimalsymbol",
                    "numberseparator",
                    "currencysymbol",
                    "dateformatstring",
                    "dateseparator",
                ],
            });
            setUserSettings(settings);
        };
        if (dataApi) fetchUserSettings();
    }, [dataApi]);
    return userSettings;
}

const formatNumber = (value: number, userSettings: any, language: string): string => {
    if (!userSettings) return new Intl.NumberFormat(language).format(value);
    const dec = userSettings.decimalsymbol || ".";
    const grp = userSettings.numberseparator || ",";
    const parts = value.toFixed(2).split(".");
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, grp);
    return parts.join(dec);
};

// --- Main Component ---
const GeneratedComponent = ({ dataApi }: GeneratedComponentProps) => {
    // Hooks must be inside the component!
    const uiLanguageId =
        (typeof Xrm !== "undefined" &&
            Xrm.Utility?.getGlobalContext()?.userSettings?.languageId) || 1033;
    const language = useMemo(() => langMap[uiLanguageId]?.code || "en-US", [uiLanguageId]);
    const isRTL = useMemo(() => langMap[uiLanguageId]?.isRtl || false, [uiLanguageId]);
    const t = (key: string): string =>
        translations[language]?.[key] || translations["en-US"]?.[key] || key;

    const userSettings = useUserSettings(dataApi);

    const [screen, setScreen] = useState<"list" | "edit">("list");
    const [workspaces, setWorkspaces] = useState<ReadableTableRow<workspace>[]>([]);
    const [loading, setLoading] = useState<boolean>(true);
    const [filterText, setFilterText] = useState<string>("");
    const [selectedWorkspace, setSelectedWorkspace] = useState<ReadableTableRow<workspace> | null>(null);
    const [renameValue, setRenameValue] = useState<string>("");
    const [renameStatus, setRenameStatus] = useState<{ success?: boolean; error?: boolean }>({});

    // Add workspace form state
    const [addForm, setAddForm] = useState<WritableTableRow<workspace>>({
        workspacename: "",
        primaryowner: "",
        secondaryowner: "",
    });
    const [addStatus, setAddStatus] = useState<{ success?: boolean; error?: boolean }>({});

    // Get current user id and email
    const currentUserId = useMemo(() => {
        return (
            (typeof Xrm !== "undefined" &&
                Xrm.Utility?.getGlobalContext()?.userSettings?.userId)
                ?.replace("{", "")
                .replace("}", "")
        );
    }, []);
    const currentUserEmail = useMemo(() => {
        return (
            (typeof Xrm !== "undefined" &&
                Xrm.Utility?.getGlobalContext()?.userSettings?.userName) || ""
        );
    }, []);

    // Fetch workspaces where user is primary or secondary owner
    const fetchWorkspaces = async () => {
        setLoading(true);
        if (!dataApi || !currentUserId) {
            setWorkspaces([]);
            setLoading(false);
            return;
        }
        const query: QueryTableOptions<workspace> = {
            select: [
                "workspaceid",
                "workspacename",
                "primaryowner",
                "secondaryowner",
            ],
            filter: [
                {
                    or: [
                        { primaryowner: currentUserId },
                        { secondaryowner: currentUserId },
                    ],
                },
            ],
            orderBy: "workspacename asc",
            pageSize: 50,
        };
        try {
            const result = await dataApi.queryTable("workspace", query);
            setWorkspaces(result.rows);
        } catch {
            setWorkspaces([]);
        }
        setLoading(false);
    };

    useEffect(() => {
        fetchWorkspaces();
        // eslint-disable-next-line
    }, [dataApi, currentUserId]);

    // Filtered workspaces
    const filteredWorkspaces = useMemo(() => {
        const s = filterText.toLowerCase();
        return workspaces.filter((w) =>
            [w.workspacename, w.primaryowner, w.secondaryowner]
                .map((f) => (f || "").toLowerCase())
                .some((f) => f.includes(s))
        );
    }, [workspaces, filterText]);

    // Columns for DataGrid
    const columns = [
        createTableColumn<ReadableTableRow<workspace>>({
            columnId: "workspacename",
            renderHeaderCell: () => (
                <Text weight="bold" size={400} style={{ padding: 8 }}>
                    {t("workspaceName")}
                </Text>
            ),
            renderCell: (item) => <TableCellLayout>{item.workspacename}</TableCellLayout>,
        }),
        createTableColumn<ReadableTableRow<workspace>>({
            columnId: "primaryowner",
            renderHeaderCell: () => (
                <Text weight="bold" size={400} style={{ padding: 8 }}>
                    {t("primaryOwner")}
                </Text>
            ),
            renderCell: (item) => <TableCellLayout>{item.primaryowner}</TableCellLayout>,
        }),
        createTableColumn<ReadableTableRow<workspace>>({
            columnId: "secondaryowner",
            renderHeaderCell: () => (
                <Text weight="bold" size={400} style={{ padding: 8 }}>
                    {t("secondaryOwner")}
                </Text>
            ),
            renderCell: (item) => <TableCellLayout>{item.secondaryowner}</TableCellLayout>,
        }),
    ];

    // Handle row click to edit
    const handleRowClick = (item: ReadableTableRow<workspace>) => {
        setSelectedWorkspace(item);
        setRenameValue(item.workspacename || "");
        setRenameStatus({});
        setScreen("edit");
    };

    // Handle rename save
    const handleRenameSave = async () => {
        if (!selectedWorkspace || !renameValue.trim()) return;
        setRenameStatus({});
        try {
            await dataApi.updateRow("workspace", selectedWorkspace.workspaceid, {
                workspacename: renameValue.trim(),
            });
            setRenameStatus({ success: true });
            // Refresh workspace list
            setScreen("list");
            setSelectedWorkspace(null);
            setRenameValue("");
            await fetchWorkspaces();
        } catch {
            setRenameStatus({ error: true });
        }
    };

    // Handle cancel
    const handleCancel = () => {
        setScreen("list");
        setSelectedWorkspace(null);
        setRenameValue("");
        setRenameStatus({});
    };

    // Handle add workspace
    const handleAddWorkspace = async () => {
        setAddStatus({});
        if (!addForm.workspacename.trim()) {
            setAddStatus({ error: true });
            return;
        }
        try {
            await dataApi.createRow("workspace", {
                workspacename: addForm.workspacename.trim(),
                primaryowner: addForm.primaryowner.trim() || currentUserId,
                secondaryowner: addForm.secondaryowner.trim(),
            });
            setAddStatus({ success: true });
            setAddForm({
                workspacename: "",
                primaryowner: "",
                secondaryowner: "",
            });
            await fetchWorkspaces();
        } catch {
            setAddStatus({ error: true });
        }
    };

    // --- Render ---
    return (
        <div
            dir={isRTL ? "rtl" : "ltr"}
            style={{
                direction: isRTL ? "rtl" : "ltr",
                flexGrow: 1,
                alignSelf: "stretch",
                width: "100%",
                height: "100%",
                padding: "20px",
                boxSizing: "border-box",
                overflow: "hidden",
                display: "flex",
                flexDirection: "column",
                background: "#f7f7f7",
            }}
        >
            {/* App Title */}
            <Text
                as="h1"
                size={700}
                weight="semibold"
                block
                style={{
                    marginBottom: "16px",
                    color: "#243A5E",
                    letterSpacing: "0.01em",
                }}
            >
                {t("appTitle")}
            </Text>

            {/* Help/Info Section */}
            <section
                aria-label={t("helpTitle")}
                style={{
                    marginBottom: "20px",
                    padding: "16px",
                    borderRadius: "8px",
                    background: "#e6f0fa",
                    boxShadow: "0 1px 3px rgba(0,0,0,0.05)",
                    maxWidth: "700px",
                }}
            >
                <Text as="h2" size={400} weight="semibold" block style={{ marginBottom: "8px" }}>
                    {t("helpTitle")}
                </Text>
                <Text size={300} block style={{ marginBottom: "4px" }}>
                    {t("helpConnected")}
                </Text>
                <Text size={300} block style={{ marginBottom: "4px" }}>
                    {t("helpManualAdd")}
                </Text>
                <Text size={300} block style={{ marginBottom: "4px" }}>
                    {t("helpSecurity")}
                </Text>
                {currentUserEmail && (
                    <Text size={300} block style={{ marginTop: "8px" }}>
                        <strong>{t("helpCurrentEmail")}</strong> {currentUserEmail}
                    </Text>
                )}
            </section>

            {/* Screen Content */}
            {screen === "list" ? (
                <WorkspaceListScreen
                    loading={loading}
                    filteredWorkspaces={filteredWorkspaces}
                    filterText={filterText}
                    setFilterText={setFilterText}
                    columns={columns}
                    handleRowClick={handleRowClick}
                    t={t}
                    addForm={addForm}
                    setAddForm={setAddForm}
                    handleAddWorkspace={handleAddWorkspace}
                    addStatus={addStatus}
                    currentUserId={currentUserId}
                />
            ) : (
                <WorkspaceEditScreen
                    workspace={selectedWorkspace}
                    renameValue={renameValue}
                    setRenameValue={setRenameValue}
                    handleRenameSave={handleRenameSave}
                    handleCancel={handleCancel}
                    renameStatus={renameStatus}
                    t={t}
                />
            )}
        </div>
    );
};

// --- Workspace List Screen ---
function WorkspaceListScreen({
    loading,
    filteredWorkspaces,
    filterText,
    setFilterText,
    columns,
    handleRowClick,
    t,
    addForm,
    setAddForm,
    handleAddWorkspace,
    addStatus,
    currentUserId,
}: {
    loading: boolean;
    filteredWorkspaces: ReadableTableRow<workspace>[];
    filterText: string;
    setFilterText: (v: string) => void;
    columns: ReturnType<typeof createTableColumn>[];
    handleRowClick: (item: ReadableTableRow<workspace>) => void;
    t: (key: string) => string;
    addForm: WritableTableRow<workspace>;
    setAddForm: (v: WritableTableRow<workspace>) => void;
    handleAddWorkspace: () => void;
    addStatus: { success?: boolean; error?: boolean };
    currentUserId: string | undefined;
}) {
    return (
        <section
            aria-label={t("workspaceListTitle")}
            style={{
                flex: 1,
                display: "flex",
                flexDirection: "column",
                background: "#fff",
                borderRadius: "8px",
                boxShadow: "0 2px 8px rgba(0,0,0,0.06)",
                padding: "20px",
                minHeight: 0,
            }}
        >
            <Text as="h2" size={500} weight="semibold" block style={{ marginBottom: "12px" }}>
                {t("workspaceListTitle")}
            </Text>
            {/* Add Workspace Form */}
            <div
                style={{
                    marginBottom: "24px",
                    padding: "16px",
                    borderRadius: "6px",
                    background: "#f9f9f9",
                    boxShadow: "0 1px 3px rgba(0,0,0,0.05)",
                    maxWidth: "480px",
                }}
            >
                <Text size={400} weight="semibold" block style={{ marginBottom: "8px" }}>
                    {t("addWorkspaceTitle")}
                </Text>
                <Input
                    value={addForm.workspacename}
                    onChange={(e, d) =>
                        setAddForm({ ...addForm, workspacename: d.value })
                    }
                    placeholder={t("workspaceNamePlaceholder")}
                    aria-label={t("workspaceName")}
                    style={{ marginBottom: "8px" }}
                />
                <Input
                    value={addForm.primaryowner}
                    onChange={(e, d) =>
                        setAddForm({ ...addForm, primaryowner: d.value })
                    }
                    placeholder={t("primaryOwnerPlaceholder")}
                    aria-label={t("primaryOwner")}
                    style={{ marginBottom: "8px" }}
                />
                <Input
                    value={addForm.secondaryowner}
                    onChange={(e, d) =>
                        setAddForm({ ...addForm, secondaryowner: d.value })
                    }
                    placeholder={t("secondaryOwnerPlaceholder")}
                    aria-label={t("secondaryOwner")}
                    style={{ marginBottom: "8px" }}
                />
                <Button
                    appearance="primary"
                    onClick={handleAddWorkspace}
                    disabled={!addForm.workspacename.trim()}
                    style={{ marginTop: "8px" }}
                >
                    {t("addWorkspace")}
                </Button>
                {addStatus.success && (
                    <Text size={300} style={{ color: "#107C10", marginTop: "8px" }}>
                        {t("addWorkspaceSuccess")}
                    </Text>
                )}
                {addStatus.error && (
                    <Text size={300} style={{ color: "#D13438", marginTop: "8px" }}>
                        {t("addWorkspaceError")}
                    </Text>
                )}
            </div>
            {/* Filter and Grid */}
            <Input
                placeholder={t("filterPlaceholder")}
                value={filterText}
                onChange={(e, d) => setFilterText(d.value)}
                style={{
                    marginBottom: "16px",
                    maxWidth: "300px",
                }}
                aria-label={t("filterPlaceholder")}
            />
            <div style={{ flex: 1, minHeight: 0, overflow: "auto" }}>
                {loading ? (
                    <Text size={400} style={{ marginTop: "24px" }}>
                        {t("loading")}
                    </Text>
                ) : filteredWorkspaces.length === 0 ? (
                    <Text size={400} style={{ marginTop: "24px" }}>
                        {t("noWorkspaces")}
                    </Text>
                ) : (
                    <DataGrid
                        items={filteredWorkspaces}
                        columns={columns}
                        sortable
                        selectionMode="single"
                        getRowId={(i) => i.workspaceid}
                        focusMode="composite"
                        aria-label={t("workspaceListTitle")}
                        style={{ minHeight: 0 }}
                        onRowClick={(e, data) => handleRowClick(data.item)}
                    >
                        <DataGridHeader>
                            <DataGridRow>
                                {({ renderHeaderCell }) => (
                                    <DataGridHeaderCell>{renderHeaderCell()}</DataGridHeaderCell>
                                )}
                            </DataGridRow>
                        </DataGridHeader>
                        <DataGridBody<ReadableTableRow<workspace>>
                            >
                            {({ item, rowId }) => (
                                <DataGridRow<ReadableTableRow<workspace>>
                                    key={rowId}
                                    style={{
                                        cursor: "pointer",
                                        transition: "background 0.2s",
                                    }}
                                >
                                    {({ renderCell }) => (
                                        <DataGridCell>{renderCell(item)}</DataGridCell>
                                    )}
                                </DataGridRow>
                            )}
                        </DataGridBody>
                    </DataGrid>
                )}
            </div>
        </section>
    );
}

// --- Workspace Edit Screen ---
function WorkspaceEditScreen({
    workspace,
    renameValue,
    setRenameValue,
    handleRenameSave,
    handleCancel,
    renameStatus,
    t,
}: {
    workspace: ReadableTableRow<workspace> | null;
    renameValue: string;
    setRenameValue: (v: string) => void;
    handleRenameSave: () => void;
    handleCancel: () => void;
    renameStatus: { success?: boolean; error?: boolean };
    t: (key: string) => string;
}) {
    if (!workspace)
        return (
            <div style={{ padding: "24px" }}>
                <Text size={400}>{t("selectWorkspace")}</Text>
            </div>
        );
    return (
        <section
            aria-label={t("editWorkspaceTitle")}
            style={{
                flex: 1,
                display: "flex",
                flexDirection: "column",
                background: "#fff",
                borderRadius: "8px",
                boxShadow: "0 2px 8px rgba(0,0,0,0.06)",
                padding: "20px",
                minHeight: 0,
                maxWidth: "480px",
                margin: "0 auto",
            }}
        >
            <Text as="h2" size={500} weight="semibold" block style={{ marginBottom: "16px" }}>
                {t("editWorkspaceTitle")}
            </Text>
            <Text size={400} block style={{ marginBottom: "8px" }}>
                {t("renameLabel")}
            </Text>
            <Input
                value={renameValue}
                onChange={(e, d) => setRenameValue(d.value)}
                aria-label={t("renameLabel")}
                style={{ marginBottom: "16px" }}
            />
            <div style={{ display: "flex", gap: "12px", marginBottom: "16px" }}>
                <Button appearance="primary" onClick={handleRenameSave} disabled={!renameValue.trim()}>
                    {t("save")}
                </Button>
                <Button appearance="secondary" onClick={handleCancel}>
                    {t("cancel")}
                </Button>
            </div>
            {renameStatus.success && (
                <Text size={300} style={{ color: "#107C10" }}>
                    {t("renameSuccess")}
                </Text>
            )}
            {renameStatus.error && (
                <Text size={300} style={{ color: "#D13438" }}>
                    {t("renameError")}
                </Text>
            )}
        </section>
    );
}

export default GeneratedComponent;