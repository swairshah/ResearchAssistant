const fs = require("fs/promises");
const os = require("os");
const path = require("path");

const bridgeDir =
	process.env.RESEARCHREADER_BRIDGE_DIR ||
	path.join(os.homedir(), "Library", "Application Support", "ResearchReader", "pi-bridge");
const contextFile = path.join(bridgeDir, "context.json");
const commandsDir = path.join(bridgeDir, "commands");
const resultsDir = path.join(bridgeDir, "results");

const EMPTY_OBJECT = {
	type: "object",
	properties: {},
	additionalProperties: false,
};

function requireBridgeDir() {
	if (!bridgeDir) {
		throw new Error("ResearchReader bridge directory is not configured.");
	}
}

async function readContext() {
	requireBridgeDir();
	const data = await fs.readFile(contextFile, "utf8");
	return JSON.parse(data);
}

async function sendCommand(command) {
	requireBridgeDir();
	const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const commandPath = path.join(commandsDir, `${id}.json`);
	const resultPath = path.join(resultsDir, `${id}.json`);
	await fs.writeFile(commandPath, JSON.stringify({ id, ...command }), "utf8");

	const timeoutMs = 30000;
	const start = Date.now();
	while (Date.now() - start < timeoutMs) {
		try {
			const resultText = await fs.readFile(resultPath, "utf8");
			const result = JSON.parse(resultText);
			await fs.unlink(resultPath).catch(() => {});
			if (!result.ok) {
				throw new Error(result.message || "Bridge command failed");
			}
			return result.message || "Done.";
		} catch (error) {
			if (error && error.code === "ENOENT") {
				await new Promise((resolve) => setTimeout(resolve, 150));
				continue;
			}
			throw error;
		}
	}

	throw new Error("Timed out waiting for ResearchReader to execute command.");
}

function toolResult(text) {
	return {
		content: [{ type: "text", text }],
		details: {},
	};
}

module.exports = function researchReaderExtension(pi) {
	pi.registerTool({
		name: "get_reader_context",
		label: "Get Reader Context",
		description: "Get the active project, current notebook, active paper, current PDF page, and saved highlights/notes from ResearchReader.",
		promptSnippet: "Read the active ResearchReader context, including the project notebook, current paper, page, and annotations.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const context = await readContext();
			return toolResult(JSON.stringify(context, null, 2));
		},
	});

	pi.registerTool({
		name: "get_project_notebook",
		label: "Get Project Notebook",
		description: "Read the current project's markdown notebook and related paper references.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const context = await readContext();
			if (!context.notebook) {
				return toolResult("No active project notebook is available.");
			}
			return toolResult(JSON.stringify(context.notebook, null, 2));
		},
	});

	pi.registerTool({
		name: "list_collections",
		label: "List Collections",
		description: "List ResearchReader collections/projects available for adding papers.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const context = await readContext();
			const collections = Array.isArray(context.collections) ? context.collections : [];
			if (collections.length === 0) {
				return toolResult("No collections found.");
			}
			return toolResult(JSON.stringify(collections, null, 2));
		},
	});

	pi.registerTool({
		name: "get_active_pdf_text",
		label: "Get Active PDF Text",
		description: "Extract text from the active paper PDF so you can summarize or analyze actual content.",
		parameters: {
			type: "object",
			properties: {
				maxPages: {
					type: "integer",
					description: "Maximum number of pages to extract (optional).",
				},
				startPage: {
					type: "integer",
					description: "1-based start page (optional).",
				},
				endPage: {
					type: "integer",
					description: "1-based end page (optional).",
				},
			},
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const payload = {
				command: "get_active_pdf_text",
			};
			if (params.maxPages !== undefined) payload.maxPages = Number(params.maxPages);
			if (params.startPage !== undefined) payload.startPage = Number(params.startPage);
			if (params.endPage !== undefined) payload.endPage = Number(params.endPage);
			const message = await sendCommand(payload);
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "go_to_pdf_page",
		label: "Go To PDF Page",
		description: "Navigate the currently open PDF view to a specific page.",
		parameters: {
			type: "object",
			properties: {
				page: {
					type: "integer",
					description: "1-based PDF page number to navigate to.",
				},
			},
			required: ["page"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const page = Number(params.page);
			const message = await sendCommand({ command: "go_to_page", page });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "focus_pdf_annotation",
		label: "Focus PDF Annotation",
		description: "Scroll the PDF view to a known annotation or saved highlight by its ID.",
		parameters: {
			type: "object",
			properties: {
				annotationId: {
					type: "string",
					description: "Annotation ID from get_reader_context, like p3-a2.",
				},
			},
			required: ["annotationId"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const annotationId = String(params.annotationId);
			const message = await sendCommand({ command: "focus_annotation", annotationId });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "preview_pdf_annotation",
		label: "Preview PDF Annotation",
		description: "Temporarily highlight an existing saved annotation in the PDF without modifying the document.",
		parameters: {
			type: "object",
			properties: {
				annotationId: {
					type: "string",
					description: "Annotation ID from get_reader_context, like p3-a2.",
				},
			},
			required: ["annotationId"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const annotationId = String(params.annotationId);
			const message = await sendCommand({ command: "preview_annotation", annotationId });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "preview_pdf_text",
		label: "Preview PDF Text",
		description: "Temporarily highlight text on a given PDF page without saving an annotation.",
		parameters: {
			type: "object",
			properties: {
				page: {
					type: "integer",
					description: "1-based PDF page number.",
				},
				text: {
					type: "string",
					description: "Text to find and preview on that page.",
				},
			},
			required: ["page", "text"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const page = Number(params.page);
			const text = String(params.text);
			const message = await sendCommand({ command: "preview_text", page, text });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "clear_pdf_preview",
		label: "Clear PDF Preview",
		description: "Clear any temporary preview highlight currently shown in the PDF.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const message = await sendCommand({ command: "clear_preview" });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "replace_project_notebook",
		label: "Replace Project Notebook",
		description: "Replace the active project's markdown notebook with new content.",
		parameters: {
			type: "object",
			properties: {
				markdown: {
					type: "string",
					description: "Full markdown content that should become the notebook body.",
				},
			},
			required: ["markdown"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const markdown = String(params.markdown);
			const message = await sendCommand({ command: "replace_notebook", markdown });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "append_project_notebook",
		label: "Append Project Notebook",
		description: "Append markdown content to the active project's notebook.",
		parameters: {
			type: "object",
			properties: {
				markdown: {
					type: "string",
					description: "Markdown block to append to the end of the notebook.",
				},
			},
			required: ["markdown"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const markdown = String(params.markdown);
			const message = await sendCommand({ command: "append_notebook", markdown });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "select_project_paper",
		label: "Select Project Paper",
		description: "Select a paper by ID from get_reader_context.projectPapers and optionally open Focus Reader.",
		parameters: {
			type: "object",
			properties: {
				paperId: {
					type: "string",
					description: "Paper UUID from get_reader_context.projectPapers[].id",
				},
				openReader: {
					type: "boolean",
					description: "When true (default), open Focus Reader after selecting the paper.",
				},
			},
			required: ["paperId"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const paperId = String(params.paperId);
			const openReader = params.openReader === undefined ? true : Boolean(params.openReader);
			const message = await sendCommand({ command: "select_paper", paperId, openReader });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "set_focus_reader_visibility",
		label: "Set Focus Reader Visibility",
		description: "Open, close, or toggle the Focus Reader panel.",
		parameters: {
			type: "object",
			properties: {
				action: {
					type: "string",
					enum: ["open", "close", "toggle"],
					description: "Visibility action.",
				},
			},
			required: ["action"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const action = String(params.action);
			const message = await sendCommand({ command: "set_focus_reader_visibility", action });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "set_notebook_visibility",
		label: "Set Notebook Visibility",
		description: "Open, close, or toggle the project notebook panel.",
		parameters: {
			type: "object",
			properties: {
				action: {
					type: "string",
					enum: ["open", "close", "toggle"],
					description: "Visibility action.",
				},
			},
			required: ["action"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const action = String(params.action);
			const message = await sendCommand({ command: "set_notebook_visibility", action });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "add_pdf_note",
		label: "Add PDF Note",
		description: "Add a note annotation in the active PDF. If text is selected, it anchors near selection.",
		parameters: {
			type: "object",
			properties: {
				text: {
					type: "string",
					description: "Note text to add.",
				},
			},
			required: ["text"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const text = String(params.text);
			const message = await sendCommand({ command: "add_note", text });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "highlight_pdf_selection",
		label: "Highlight PDF Selection",
		description: "Highlight the current text selection in the active PDF.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const message = await sendCommand({ command: "highlight_selection" });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "remove_pdf_highlights_in_selection",
		label: "Remove PDF Highlights In Selection",
		description: "Remove highlight(s) intersecting current selection or the last clicked highlight.",
		parameters: EMPTY_OBJECT,
		async execute() {
			const message = await sendCommand({ command: "remove_highlights_in_selection" });
			return toolResult(message);
		},
	});

	pi.registerTool({
		name: "add_paper_to_collection",
		label: "Add Paper To Collection",
		description: "Add a paper (metadata) to a collection/project. Useful after web search.",
		parameters: {
			type: "object",
			properties: {
				title: {
					type: "string",
					description: "Paper title.",
				},
				authors: {
					type: "array",
					items: { type: "string" },
					description: "Author names.",
				},
				venue: {
					type: "string",
					description: "Venue or source (optional).",
				},
				year: {
					type: "integer",
					description: "Publication year (optional).",
				},
				doi: {
					type: "string",
					description: "DOI (optional).",
				},
				arxivId: {
					type: "string",
					description: "arXiv identifier (optional).",
				},
				abstractText: {
					type: "string",
					description: "Abstract text (optional).",
				},
				sourceUrl: {
					type: "string",
					description: "Source URL for traceability (optional).",
				},
				pdfUrl: {
					type: "string",
					description: "Direct PDF URL (optional but recommended so the paper is fully openable).",
				},
				collectionName: {
					type: "string",
					description: "Target collection/project name (optional, defaults to active project).",
				},
			},
			required: ["title"],
			additionalProperties: false,
		},
		async execute(_toolCallId, params) {
			const message = await sendCommand({
				command: "add_paper_to_collection",
				title: String(params.title),
				authors: Array.isArray(params.authors) ? params.authors.map(String) : [],
				venue: params.venue === undefined ? undefined : String(params.venue),
				year: params.year === undefined ? undefined : Number(params.year),
				doi: params.doi === undefined ? undefined : String(params.doi),
				arxivId: params.arxivId === undefined ? undefined : String(params.arxivId),
				abstractText: params.abstractText === undefined ? undefined : String(params.abstractText),
				sourceUrl: params.sourceUrl === undefined ? undefined : String(params.sourceUrl),
				pdfUrl: params.pdfUrl === undefined ? undefined : String(params.pdfUrl),
				collectionName: params.collectionName === undefined ? undefined : String(params.collectionName),
			});
			return toolResult(message);
		},
	});
};
