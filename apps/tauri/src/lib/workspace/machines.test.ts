import { describe, expect, it } from "vitest";
import { isValidHost, isValidRemoteFolder, machineFolderLabel, suggestedName } from "./machines";

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
