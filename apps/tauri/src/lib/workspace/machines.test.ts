import { describe, expect, it } from "vitest";
import { folderFor, isValidHost, isValidRemoteFolder, machineFolderLabel, projectKey, sharedMachines, suggestedName } from "./machines";
import { FRESH_FOR, isStale } from "./machine-status.svelte";

describe("machines", () => {
  it("takes ssh destinations, never options", () => {
    expect(isValidHost("buildbox")).toBe(true);
    expect(isValidHost("me@10.0.0.4")).toBe(true);
    expect(isValidHost("-oProxyCommand=calc")).toBe(false);
    expect(isValidHost("me@host; rm -rf ~")).toBe(false);
    expect(isValidHost(" ")).toBe(false);
  });

  it("takes folders from / or the home folder there", () => {
    expect(isValidRemoteFolder("~")).toBe(true);
    expect(isValidRemoteFolder("~/code/app")).toBe(true);
    expect(isValidRemoteFolder("/srv/app")).toBe(true);
    expect(isValidRemoteFolder("code/app")).toBe(false);
    expect(isValidRemoteFolder("C:\\code")).toBe(false);
  });

  it("names a machine after its host, as the core does", () => {
    expect(suggestedName("me@buildbox.local")).toBe("buildbox");
    expect(suggestedName("10.0.0.4")).toBe("10.0.0.4");
    expect(suggestedName("devbox")).toBe("devbox");
  });

  it("labels a folder on a machine", () => {
    expect(machineFolderLabel({ name: "buildbox" }, "~/code/app/")).toBe("buildbox:app");
    expect(machineFolderLabel({ name: "buildbox" }, "~")).toBe("buildbox:~");
    expect(machineFolderLabel({ name: "buildbox" }, "")).toBe("buildbox:…");
  });
});

describe("shared projects", () => {
  const box = { id: "b", name: "box", host: "h", projectFolders: { "C:\\code\\app": "~/app", "/me/web": "/srv/web" } };

  it("finds the project's folder on a machine", () => {
    expect(projectKey("C:\\code\\app\\")).toBe("C:\\code\\app");
    expect(folderFor(box, "C:\\code\\app\\")).toBe("~/app");
    expect(folderFor(box, "/me/web/")).toBe("/srv/web");
    expect(folderFor(box, "/me/other")).toBeNull();
  });

  it("offers only shared machines that are not manual only", () => {
    const manual = { ...box, id: "m", balance: "manualOnly" as const };
    expect(sharedMachines([box, manual], "/me/web").map((m) => m.id)).toEqual(["b"]);
    expect(sharedMachines([box], "/me/other")).toEqual([]);
  });

  it("asks a machine again after two minutes", () => {
    expect(isStale(undefined, 0)).toBe(true);
    expect(isStale(1000, 1000 + FRESH_FOR - 1)).toBe(false);
    expect(isStale(1000, 1000 + FRESH_FOR)).toBe(true);
  });
});
