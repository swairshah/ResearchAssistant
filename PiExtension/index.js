const fs = require("fs/promises");
const path = require("path");

const bridgeDir = process.env.RESEARCHREADER_BRIDGE_DIR;
const contextFile = bridgeDir ? path.join(bridgeDir, "context.json") : null;
const commandsDir = bridgeDir ? path.join(bridgeDir, "commands") : null;
const resultsDir = bridgeDir ? path.join(bridgeDir, "results") : null;

const EMPTY_OBJECT = {
	type: "object",
	properties: {},
	additionalProperties: false,
};

function requireBridgeDir() {
	if (!bridgeDir || !contextFile || !commandsDir || !resultsDir) {
		throw new Error("RESEARCHREADER_BRIDGE_DIR is not configured.");
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

	const timeoutMs = 4000;
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
};
