#!/usr/bin/env bun
//
// Reads what a workflow file declares about one exec node, so a test can run
// the real node body and hold its real output to the declared schema.
//
// Without this the two halves of a node are only ever checked apart: bats runs
// the script with the workflow absent, and `archon workflow test` stubs the
// body away and checks the DAG with the script absent. Rename a field on one
// side only and both suites stay green while a real run dies on the exec
// output contract.

interface PropertySchema {
  type: string;
}

interface OutputFormat {
  type: string;
  properties: Record<string, PropertySchema>;
  required: string[];
}

interface WorkflowNode {
  id: string;
  bash?: string;
  output_format?: unknown;
}

const SCALAR_TYPES = new Set(["string", "boolean", "number", "integer"]);

/** Exit 2: this harness cannot judge the node, which is never a verdict on it. */
function unusable(message: string): never {
  console.error(`workflow-node: ${message}`);
  process.exit(2);
}

/** Exit 1: the node was judged and does not hold up. */
function mismatch(message: string): never {
  console.error(`workflow-node: ${message}`);
  process.exit(1);
}

/**
 * Refuses a schema using anything past `{type: object, properties, required}`
 * over scalars. An unrecognised construct has to stop the run rather than go
 * unchecked, or this helper reports a pass it never established.
 */
function asOutputFormat(schema: unknown, nodeId: string): OutputFormat {
  if (typeof schema !== "object" || schema === null) {
    unusable(`node '${nodeId}' declares no output_format`);
  }
  const keys = Object.keys(schema);
  const unsupported = keys.filter(
    (key) => !["type", "properties", "required"].includes(key),
  );
  if (unsupported.length > 0) {
    unusable(
      `node '${nodeId}' output_format uses ${unsupported.join(", ")}, which this helper cannot check`,
    );
  }

  const { type, properties, required } = schema as Record<string, unknown>;
  if (type !== "object") {
    unusable(`node '${nodeId}' output_format is type '${String(type)}', expected object`);
  }
  if (typeof properties !== "object" || properties === null) {
    unusable(`node '${nodeId}' output_format declares no properties`);
  }
  if (!Array.isArray(required)) {
    unusable(`node '${nodeId}' output_format declares no required list`);
  }

  for (const [name, spec] of Object.entries(properties)) {
    const propertyType = (spec as Record<string, unknown>)?.type;
    if (typeof propertyType !== "string" || !SCALAR_TYPES.has(propertyType)) {
      unusable(
        `node '${nodeId}' property '${name}' has type '${String(propertyType)}', which this helper cannot check`,
      );
    }
  }

  return {
    type,
    properties: properties as Record<string, PropertySchema>,
    required: required as string[],
  };
}

function jsonTypeOf(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

function typeMatches(declared: string, actual: string): boolean {
  if (declared === "number") return actual === "number" || actual === "integer";
  return declared === actual;
}

function loadNode(yamlPath: string, nodeId: string): WorkflowNode {
  const workflow = Bun.YAML.parse(readFileText(yamlPath)) as { nodes?: WorkflowNode[] };
  const node = (workflow?.nodes ?? []).find((candidate) => candidate?.id === nodeId);
  if (!node) unusable(`no node '${nodeId}' in ${yamlPath}`);
  return node;
}

function readFileText(path: string): string {
  try {
    return require("fs").readFileSync(path, "utf8");
  } catch (error) {
    unusable(`cannot read ${path}: ${(error as Error).message}`);
  }
}

function commandBody(node: WorkflowNode): string {
  if (typeof node.bash !== "string") {
    unusable(`node '${node.id}' has no bash body`);
  }
  return node.bash;
}

async function checkOutput(node: WorkflowNode): Promise<void> {
  const schema = asOutputFormat(node.output_format, node.id);
  const text = await Bun.stdin.text();

  let document: unknown;
  try {
    document = JSON.parse(text);
  } catch (error) {
    // The engine holds an exec node to exactly one JSON document on stdout, and
    // JSON.parse rejects two concatenated ones, so this covers that rule too.
    mismatch(
      `node '${node.id}' did not print exactly one JSON document: ${(error as Error).message}`,
    );
  }
  if (jsonTypeOf(document) !== "object") {
    mismatch(`node '${node.id}' printed a ${jsonTypeOf(document)}, expected an object`);
  }

  const emitted = document as Record<string, unknown>;
  const problems: string[] = [];

  for (const name of schema.required) {
    if (!(name in emitted)) problems.push(`missing required key '${name}'`);
  }
  for (const [name, value] of Object.entries(emitted)) {
    const declared = schema.properties[name];
    if (!declared) {
      problems.push(`emitted key '${name}' is not declared in output_format`);
      continue;
    }
    const actual = jsonTypeOf(value);
    if (!typeMatches(declared.type, actual)) {
      problems.push(`key '${name}' is ${actual}, output_format declares ${declared.type}`);
    }
  }

  if (problems.length > 0) {
    mismatch(`node '${node.id}' output does not match its output_format:\n  ${problems.join("\n  ")}`);
  }
}

const [command, yamlPath, nodeId] = process.argv.slice(2);
if (!command || !yamlPath || !nodeId) {
  unusable("usage: workflow-node.ts <body|check-output> <workflow.yaml> <node-id>");
}

const node = loadNode(yamlPath, nodeId);
switch (command) {
  case "body":
    console.log(commandBody(node));
    break;
  case "check-output":
    await checkOutput(node);
    break;
  default:
    unusable(`unknown command '${command}'`);
}
