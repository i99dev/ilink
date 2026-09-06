package com.i99dev.ilink.security;

import com.google.protobuf.TextFormat;
import com.i99dev.ilink.car.CarTableProto;
import com.i99dev.ilink.miniapps.MiniAppTableProto;
import org.junit.Test;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;
import java.security.MessageDigest;
import static org.junit.Assert.*;

/** Parses the actual shipped assets with the production schema, without Android or network. */
public class OfflineTableAssetsTest {
    private static String readUtf8(Path path) throws java.io.IOException {
        return new String(Files.readAllBytes(path), java.nio.charset.StandardCharsets.UTF_8);
    }

    private Path assets() {
        return Path.of(System.getProperty("offline.assets", "src/main/assets/offline"));
    }

    private CarTableProto.CarTable carTable() throws Exception {
        var builder = CarTableProto.CarTable.newBuilder();
        TextFormat.getParser().merge(readUtf8(assets().resolve("car_table.textproto")), builder);
        return builder.build();
    }

    @Test public void carTableHasRealNamedActionsAndCompleteUnitReferences() throws Exception {
        var table = carTable();
        assertFalse(table.getVersion().isBlank());
        assertTrue(table.getFastActionsCount() > 0);
        Set<String> actions = new HashSet<>();
        Set<String> units = new HashSet<>();
        for (var unit : table.getUnitsList()) {
            assertTrue(units.add(unit.getName()));
            assertTrue(unit.getDexFilename().matches("[A-Za-z0-9_-]+\\.dex"));
            assertFalse(unit.getClassName().isBlank());
            assertTrue(Files.size(assets().resolve("units").resolve(unit.getDexFilename())) > 0);
        }
        for (var action : table.getFastActionsList()) {
            assertTrue(actions.add(action.getActionId()));
            assertFalse(action.getFeatureName().isBlank());
            assertNotEquals(CarTableProto.ValueSpec.KindCase.KIND_NOT_SET, action.getValue().getKindCase());
        }
        for (var action : table.getUnitActionsList()) {
            assertTrue(actions.add(action.getActionId()));
            assertTrue(units.contains(action.getUnitName()));
        }
        assertEquals(table, CarTableProto.CarTable.parseFrom(table.toByteArray()));
    }

    @Test public void miniAppRoutesRetainScopesAndModelConstraints() throws Exception {
        var builder = MiniAppTableProto.MiniAppTable.newBuilder();
        TextFormat.getParser().merge(readUtf8(assets().resolve("mini_app_table.textproto")), builder);
        var table = builder.build();
        assertTrue(table.getOpsCount() > 0);
        Set<String> families = new HashSet<>();
        for (var family : table.getFamiliesList()) families.add(family.getFamilyId());
        for (var op : table.getOpsList()) {
            assertTrue(families.contains(op.getFamilyId()));
            assertFalse(op.getRequiredScope().isBlank());
            assertTrue(op.getOpToken().matches("[a-f0-9]{16}"));
            assertNotEquals(MiniAppTableProto.NativeKind.NATIVE_KIND_UNSPECIFIED, op.getKind());
        }
        assertEquals(table, MiniAppTableProto.MiniAppTable.parseFrom(table.toByteArray()));
    }

    @Test public void everyShippedDexMatchesManifestAndItsInternalSignature() throws Exception {
        String manifest = readUtf8(assets().resolve("units/manifest.json"));
        for (var unit : carTable().getUnitsList()) {
            byte[] dex = Files.readAllBytes(assets().resolve("units").resolve(unit.getDexFilename()));
            assertEquals("dex\n", new String(dex, 0, 4, java.nio.charset.StandardCharsets.US_ASCII));
            byte[] signature = MessageDigest.getInstance("SHA-1").digest(java.util.Arrays.copyOfRange(dex, 32, dex.length));
            assertArrayEquals(java.util.Arrays.copyOfRange(dex, 12, 32), signature);
            String hash = java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(dex));
            assertTrue(manifest.contains("\"" + unit.getDexFilename() + "\""));
            assertTrue(manifest.contains("\"" + hash + "\""));
        }
    }

    @Test public void defaultEnglishModelIsBundledWithCompleteKaldiFilesAndHash() throws Exception {
        Path archive = assets().resolve("voice/en-0.15.zip");
        assertEquals(41205931L, Files.size(archive));
        String hash = java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(archive)));
        assertEquals("30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498", hash);
        Set<String> entries = new HashSet<>();
        try (var zip = new java.util.zip.ZipInputStream(Files.newInputStream(archive))) {
            java.util.zip.ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                assertFalse(entry.getName().contains(".."));
                entries.add(entry.getName());
                zip.transferTo(java.io.OutputStream.nullOutputStream()); // verifies every compressed entry CRC
                zip.closeEntry();
            }
        }
        String root = "vosk-model-small-en-us-0.15/";
        for (String file : new String[]{"am/final.mdl", "conf/model.conf", "conf/mfcc.conf", "graph/HCLr.fst", "graph/Gr.fst", "README"}) {
            assertTrue(entries.contains(root + file));
        }
        assertTrue(readUtf8(assets().resolve("voice/LICENSE-APACHE-2.0.txt")).contains("Apache License"));
    }
}
