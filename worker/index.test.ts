import { describe, expect, it } from "vitest";
import { handleRequest } from "./index";
import { encodeSse } from "./sse";
import { FakeD1, fakeCtx } from "./test-helpers";
import type { Deps, Env } from "./types";

function makeEnv(db: FakeD1): Env {
  return {
    DB: db as unknown as D1Database,
    ASSETS: { fetch: () => Promise.resolve(new Response("asset")) } as unknown as Fetcher,
    ENCRYPTION_KEY: "test-encryption-secret-with-enough-entropy",
    CURSOR_API_BASE: "https://api.cursor.test"
  };
}

describe("Worker", () => {
  it("signs up a Cursor API key and serves chat completions", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const signup = await handleRequest(
      new Request("https://composer.test/api/signup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cursorApiKey: "cursor_key", name: "Ada", email: "ada@example.com", joinWaitlist: true })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(signup.status).toBe(200);
    const signupBody = (await signup.json()) as { apiKey: string; endpoints: { chatCompletions: string } };
    expect(signupBody.apiKey).toMatch(/^cmp_/);
    expect(signupBody.endpoints.chatCompletions).toContain("/u/acct_");

    const completion = await handleRequest(
      new Request(signupBody.endpoints.chatCompletions, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${signupBody.apiKey}`
        },
        body: JSON.stringify({
          model: "composer-2.5",
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(200);
    await expect(completion.json()).resolves.toMatchObject({
      object: "chat.completion",
      choices: [{ message: { content: "Hello from Composer" } }]
    });
    expect([...db.requestLogs.values()].at(-1)).toMatchObject({
      status: "completed",
      completion_chars: "Hello from Composer".length
    });
  });

  it("serves bare /v1/chat/completions with a direct Cursor key and writes no request log", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, agentAuthHeaders } = fakeDeps();

    const completion = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(200);
    await expect(completion.json()).resolves.toMatchObject({
      object: "chat.completion",
      choices: [{ message: { content: "Hello from Composer" } }]
    });

    // Direct mode must not persist anything to D1.
    expect(db.requestLogs.size).toBe(0);
    expect(db.accounts.size).toBe(0);
    expect(db.apiKeys.size).toBe(0);

    // The caller's own key is forwarded to Cursor unchanged.
    expect(agentAuthHeaders).toContain("Bearer cursor_direct_key");
  });

  it("streams SSE chat chunks in direct mode when stream is true", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, agentAuthHeaders } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain('"object":"chat.completion.chunk"');
    expect(body).toContain('"content":"Hello from Composer"');
    expect(body).toContain('"finish_reason":"stop"');
    expect(body).toContain("data: [DONE]");

    expect(db.requestLogs.size).toBe(0);
    expect(agentAuthHeaders).toContain("Bearer cursor_direct_key");
  });

  it("streams SSE response events in direct mode for /v1/responses", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({ model: "composer-2.5", stream: true, input: "Say hello" })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain("event: response.created");
    expect(body).toContain("event: response.output_text.delta");
    expect(body).toContain("event: response.completed");
    expect(body).toContain("Hello from Composer");
    expect(db.requestLogs.size).toBe(0);
  });

  it("returns a buffered JSON response for /v1/responses when stream is absent", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const response = await handleRequest(
      new Request("https://composer.test/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cursor_direct_key"
        },
        body: JSON.stringify({ model: "composer-2.5", input: "Say hello" })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/json");
    await expect(response.json()).resolves.toMatchObject({
      object: "response",
      output: [{ type: "message", content: [{ type: "output_text", text: "Hello from Composer" }] }]
    });
  });

  it("streams SSE chat chunks in legacy cmp_ proxy mode and still writes a request log", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const signup = await handleRequest(
      new Request("https://composer.test/api/signup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cursorApiKey: "cursor_key" })
      }),
      env,
      fakeCtx(),
      deps
    );
    const signupBody = (await signup.json()) as { apiKey: string; endpoints: { chatCompletions: string } };

    const response = await handleRequest(
      new Request(signupBody.endpoints.chatCompletions, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${signupBody.apiKey}`
        },
        body: JSON.stringify({
          model: "composer-2.5",
          stream: true,
          messages: [{ role: "user", content: "Say hello" }]
        })
      }),
      env,
      fakeCtx(),
      deps
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const body = await response.text();
    expect(body).toContain('"object":"chat.completion.chunk"');
    expect(body).toContain('"content":"Hello from Composer"');
    expect(body).toContain("data: [DONE]");

    // Proxy mode still records a request log; streaming completes it asynchronously.
    expect(db.requestLogs.size).toBe(1);
  });

  it("requires a bearer token for /v1/models", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps } = fakeDeps();

    const noAuth = await handleRequest(
      new Request("https://composer.test/v1/models"),
      env,
      fakeCtx(),
      deps
    );
    expect(noAuth.status).toBe(401);

    const withAuth = await handleRequest(
      new Request("https://composer.test/v1/models", {
        headers: { Authorization: "Bearer cursor_direct_key" }
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(withAuth.status).toBe(200);
    await expect(withAuth.json()).resolves.toMatchObject({ object: "list" });
  });

  it("rejects an unknown cmp_ token without forwarding it to Cursor", async () => {
    const db = new FakeD1();
    const env = makeEnv(db);
    const { deps, agentAuthHeaders } = fakeDeps();

    const completion = await handleRequest(
      new Request("https://composer.test/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer cmp_not_a_real_key"
        },
        body: JSON.stringify({ model: "composer-2.5", messages: [{ role: "user", content: "Hi" }] })
      }),
      env,
      fakeCtx(),
      deps
    );
    expect(completion.status).toBe(401);
    // An invalid cmp_ token is never forwarded to Cursor as a Cursor key.
    expect(agentAuthHeaders).toHaveLength(0);
  });
});

function fakeDeps(): { deps: Deps; agentAuthHeaders: string[] } {
  const agentAuthHeaders: string[] = [];
  const deps: Deps = {
    now: () => new Date("2026-05-20T12:00:00.000Z"),
    randomUUID: () => "00000000-0000-4000-8000-000000000000",
    fetch: async (input, init) => {
      const url = new URL(String(input));
      const auth = new Headers(init?.headers).get("authorization") || "";
      if (url.pathname === "/v1/me") {
        return Response.json({
          apiKeyName: "Test key",
          userId: 123,
          userEmail: "ada@example.com",
          userFirstName: "Ada",
          userLastName: "Lovelace",
          createdAt: "2026-05-20T00:00:00.000Z"
        });
      }
      if (url.pathname === "/v1/agents" && init?.method === "POST") {
        agentAuthHeaders.push(auth);
        const body = JSON.parse(String(init.body || "{}")) as { prompt?: { text?: string }; model?: { id?: string } };
        expect(body.prompt?.text).toContain("Say hello");
        expect(body.model?.id).toBe("composer-latest");
        return Response.json({
          agent: { id: "bc-00000000-0000-4000-8000-000000000000", latestRunId: "run-00000000-0000-4000-8000-000000000000" },
          run: { id: "run-00000000-0000-4000-8000-000000000000", status: "RUNNING" }
        });
      }
      if (url.pathname.endsWith("/stream")) {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(encodeSse({ type: "text-delta", text: "Hello from Composer" }, "interaction_update"));
              controller.enqueue(encodeSse({ status: "FINISHED", result: "Hello from Composer" }, "result"));
              controller.close();
            }
          }),
          { headers: { "Content-Type": "text/event-stream" } }
        );
      }
      return new Response("not found", { status: 404 });
    }
  };
  return { deps, agentAuthHeaders };
}
