import React from "react";

import { resolvablePromise } from "@excalidraw/common";

import { Excalidraw } from "../index";

import { getToolbarTools } from "../components/shapes";

import { Pointer } from "./helpers/ui";
import { act, render } from "./test-utils";

import type { AppClassProperties, ExcalidrawImperativeAPI } from "../types";

describe("setActiveTool()", () => {
  const h = window.h;

  let excalidrawAPI: ExcalidrawImperativeAPI;

  const mouse = new Pointer("mouse");

  beforeEach(async () => {
    const excalidrawAPIPromise = resolvablePromise<ExcalidrawImperativeAPI>();
    await render(
      <Excalidraw
        onExcalidrawAPI={(api) => excalidrawAPIPromise.resolve(api as any)}
      />,
    );
    excalidrawAPI = await excalidrawAPIPromise;
  });

  it("should expose setActiveTool on package API", () => {
    expect(excalidrawAPI.setActiveTool).toBeDefined();
    expect(excalidrawAPI.setActiveTool).toBe(h.app.setActiveTool);
  });

  it("should set the active tool type", async () => {
    expect(h.state.activeTool.type).toBe("selection");
    act(() => {
      excalidrawAPI.setActiveTool({ type: "rectangle" });
    });
    expect(h.state.activeTool.type).toBe("rectangle");

    mouse.down(10, 10);
    mouse.up(20, 20);

    expect(h.state.activeTool.type).toBe("selection");
  });

  it("should support tool locking", async () => {
    expect(h.state.activeTool.type).toBe("selection");
    act(() => {
      excalidrawAPI.setActiveTool({ type: "rectangle", locked: true });
    });
    expect(h.state.activeTool.type).toBe("rectangle");

    mouse.down(10, 10);
    mouse.up(20, 20);

    expect(h.state.activeTool.type).toBe("rectangle");
  });

  it("should set custom tool", async () => {
    expect(h.state.activeTool.type).toBe("selection");
    act(() => {
      excalidrawAPI.setActiveTool({ type: "custom", customType: "comment" });
    });
    expect(h.state.activeTool.type).toBe("custom");
    expect(h.state.activeTool.customType).toBe("comment");
  });
});
describe("getToolbarTools()", () => {
  const getToolValues = (preferredSelectionTool: "selection" | "lasso") =>
    getToolbarTools({
      state: {
        preferredSelectionTool: {
          type: preferredSelectionTool,
        },
      },
    } as AppClassProperties).map((tool) => tool.value);

  it("does not include lasso when selection is preferred", () => {
    const toolValues = getToolValues("selection");

    expect(toolValues.filter((value) => value === "selection")).toHaveLength(1);
    expect(toolValues.filter((value) => value === "lasso")).toHaveLength(0);
  });

  it("replaces selection with lasso when lasso is preferred", () => {
    const toolValues = getToolValues("lasso");

    expect(toolValues.filter((value) => value === "lasso")).toHaveLength(1);
    expect(toolValues.filter((value) => value === "selection")).toHaveLength(0);
  });
});

describe("star tool", () => {
  const h = window.h;

  it("is included in getToolbarTools()", () => {
    const toolValues = getToolbarTools({
      state: {
        preferredSelectionTool: {
          type: "selection",
        },
      },
    } as AppClassProperties).map((tool) => tool.value);

    expect(toolValues).toContain("star");
  });

  it("is present and selectable in the toolbar", async () => {
    const { getByToolName } = await render(<Excalidraw />);
    const tool = getByToolName("star");

    expect(tool).toBeTruthy();
    act(() => {
      tool.click();
    });
    expect(h.state.activeTool.type).toBe("star");
  });

  it("shows NEW badge on the star toolbar button", async () => {
    const { getByToolName } = await render(<Excalidraw />);
    const starButton = getByToolName("star");
    const badge = starButton
      .closest("label")
      ?.querySelector(".ToolIcon__badge");

    expect(badge).toBeTruthy();
    expect(badge).toHaveTextContent("NEW");
  });
});
