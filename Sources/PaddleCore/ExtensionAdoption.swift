import Foundation

/// Hand-installed add-ons (an addons.mozilla.org download put into `extensions/` by hand) that can join the update
/// check: which folders are candidates, and which store answers are acceptable. Pure; the prompts and lookups are in
/// `ExtensionUpdater`.
public enum ExtensionAdoption {
    /// The add-on id a manifest names: `browser_specific_settings.gecko.id`, else `applications.gecko.id`.
    public static func geckoID(manifest: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any] else { return nil }
        for key in ["browser_specific_settings", "applications"] {
            if let gecko = (root[key] as? [String: Any])?["gecko"] as? [String: Any],
               let id = gecko["id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    /// The gecko id of `folder` when it is a candidate for adoption: a plain folder name (not starting with ".", no
    /// "/"), a gecko id in its manifest, no record in the sources file, and not in the declined list. Nil otherwise.
    public static func candidateGeckoID(folder: String, manifest: Data, sources: ExtensionSources) -> String? {
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/"), folder != ExtensionSources.declinedKey,
              sources.records[folder] == nil, !sources.hasDeclinedAdoption(folder) else { return nil }
        return geckoID(manifest: manifest)
    }

    /// Whether a store lookup may be offered for a folder: the add-on's guid must equal the manifest's gecko id exactly.
    public static func acceptsLookup(guid: String, geckoID: String) -> Bool {
        !geckoID.isEmpty && guid == geckoID
    }

    /// Whether the first update of this record must show the permission alert even when it asks for nothing new.
    public static func needsAlertOnFirstUpdate(record: ExtensionSources.Record) -> Bool {
        record.adopted == true
    }
}
