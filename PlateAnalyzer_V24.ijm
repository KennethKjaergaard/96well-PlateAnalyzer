// ============================================================
//   PlateAnalyzer.ijm  -  Version v11.0
//   (Fixed plate-wide threshold, measurements on raw data)
// ============================================================
// Counts FITC-POSITIVE cells per well and measures their intensity.
//
// What is new compared with v10.6:
//  - Optional FIXED threshold for the whole plate (defines "FITC-positive"
//    the same way in every well). Optional helper finds it from a negative control.
//  - Filters (background subtraction, median) are used for DETECTION only.
//    Intensities are measured on the RAW image.
//  - Optional background value subtracted from all intensity measurements.
//  - Particle size is in PIXELS (matches the cell presets, also on calibrated images).
//  - Preview: choose which well to preview and test the same settings on more wells.
//  - Threshold used, raw image max and median cell intensity are saved per well.
//  - QC images are saved for ALL wells (also empty ones), with optional fixed display range.
//  - Analysis_Settings.txt is saved for reproducibility.
// Column names in A_Summary_Table.csv are unchanged (new columns are added at the end).
// ============================================================

// ---------- Global settings (var = visible inside functions) ----------
var inputDir = "";
var outputDir = "";
var fitcSuffix = "_w1";
var minSize = 250;
var maxSize = 2500;
var minCirc = 0.10;
var maxCirc = 1.00;
var bgRadius = 30;       // 30 px matches cells up to 400 px^2 without removing intracellular signal
var medianRadius = 2;
var excludeEdge = true;
var showPreview = true;
var userLower = 0;
var userUpper = 255;
var cellPreset = "Custom";
var threshMethod = "Triangle";
var fixedThr = 0;        // 0 = use algorithm; >0 = fixed lower threshold for ALL wells
var bgValue = 0;         // raw-intensity background subtracted from measurements (0 = none)
var doHelper = false;
var previewLabel = "";
var particleOptions = "";

setOption("BlackBackground", true);

fitcPaths = newArray(0);
wellLabels = newArray(0);

// ============================================================
// STEP 1: Settings + preview loop
// ============================================================
settingsSatisfied = false;
while (!settingsSatisfied) {

    Dialog.create("PlateAnalyzer v11.0");
    Dialog.addDirectory("Input folder:", inputDir);
    Dialog.addDirectory("Output folder:", outputDir);
    Dialog.addString("FITC suffix:", fitcSuffix);
    Dialog.addCheckbox("Exclude cells at the edge", excludeEdge);
    Dialog.addCheckbox("Show live preview (recommended)", showPreview);

    Dialog.addMessage("--- Pre-processing (used for DETECTION only, not for measurement) ---");
    Dialog.addNumber("Background subtraction radius (0 = off):", bgRadius);
    Dialog.addMessage("Tip: radius 30 fits cells up to 400 px^2 without removing intracellular signal.");
    Dialog.addNumber("Median filter radius (0 = off):", medianRadius);

    Dialog.addMessage("--- Threshold: what counts as FITC-positive ---");
    Dialog.addMessage("Recommended: ONE fixed threshold for the whole plate, set on negative controls.");
    Dialog.addNumber("Fixed threshold, whole plate (0 = use algorithm below):", fixedThr);
    Dialog.addChoice("Threshold algorithm (only used if fixed = 0):", newArray("Triangle", "Otsu", "Huang", "Manual"), threshMethod);
    Dialog.addCheckbox("Help me find the threshold from a negative control well", doHelper);
    Dialog.addNumber("Background to subtract from measurements (raw units, 0 = none):", bgValue);

    Dialog.addMessage("--- Particle settings ---");
    Dialog.addMessage("Info: CHO (120-350 px) | HAEC (120-400 px). Sizes are in PIXELS.");
    Dialog.addChoice("Cell preset:", newArray("Custom", "CHO cells (120-350 px)", "HAEC cells (120-400 px)"), cellPreset);
    Dialog.addNumber("Min. size (px^2):", minSize);
    Dialog.addNumber("Max. size (px^2):", maxSize);
    Dialog.addNumber("Min. circularity (0.0 - 1.0):", minCirc);
    Dialog.addNumber("Max. circularity (0.0 - 1.0):", maxCirc);
    Dialog.show();

    // Read values (order within each type must match the order above)
    inputDir     = Dialog.getString();
    outputDir    = Dialog.getString();
    fitcSuffix   = Dialog.getString();

    excludeEdge  = Dialog.getCheckbox();
    showPreview  = Dialog.getCheckbox();
    doHelper     = Dialog.getCheckbox();

    bgRadius     = Dialog.getNumber();
    medianRadius = Dialog.getNumber();
    fixedThr     = Dialog.getNumber();
    bgValue      = Dialog.getNumber();
    minSize      = Dialog.getNumber();
    maxSize      = Dialog.getNumber();
    minCirc      = Dialog.getNumber();
    maxCirc      = Dialog.getNumber();

    threshMethod = Dialog.getChoice();
    cellPreset   = Dialog.getChoice();

    if (cellPreset == "CHO cells (120-350 px)") {
        minSize = 120;
        maxSize = 350;
    } else if (cellPreset == "HAEC cells (120-400 px)") {
        minSize = 120;
        maxSize = 400;
    }

    inputDir = replace(inputDir, "\\", "/");
    outputDir = replace(outputDir, "\\", "/");
    if (!endsWith(inputDir, "/")) inputDir += "/";
    if (!endsWith(outputDir, "/")) outputDir += "/";

    // size= is in pixels ("pixel" keyword), so presets match on calibrated images too
    particleOptions = "size=" + minSize + "-" + maxSize + " pixel circularity=" + minCirc + "-" + maxCirc + " show=Nothing add";
    if (excludeEdge) particleOptions += " exclude";

    // Find FITC images
    fitcEnding = fitcSuffix + ".tif";
    allFiles = getFileList(inputDir);
    fitcPaths = newArray(0);
    wellLabels = newArray(0);
    for (i = 0; i < allFiles.length; i++) {
        if (endsWith(allFiles[i], fitcEnding)) {
            label = substring(allFiles[i], 0, lengthOf(allFiles[i]) - lengthOf(fitcEnding));
            wellLabels = Array.concat(wellLabels, label);
            fitcPaths = Array.concat(fitcPaths, inputDir + allFiles[i]);
        }
    }
    if (fitcPaths.length == 0) {
        showMessage("Error", "No files found in the input folder matching the suffix: " + fitcEnding);
        exit();
    }

    if (!showPreview && threshMethod == "Manual" && fixedThr == 0) {
        exit("Manual thresholding needs the live preview. Enable the preview or set a fixed threshold.");
    }

    // Optional: threshold / background suggestion from a negative control
    if (doHelper) {
        Dialog.create("Negative control well");
        Dialog.addMessage("Pick a well WITHOUT FITC-positive cells (e.g. untransfected or unstained).");
        Dialog.addChoice("Negative control well:", wellLabels, wellLabels[0]);
        Dialog.addNumber("Suggested threshold = mean + k x SD, k =", 5);
        Dialog.show();
        ctrlLabel = Dialog.getChoice();
        kSD = Dialog.getNumber();
        controlHelper(fitcPaths[findIndex(wellLabels, ctrlLabel)], kSD);
        doHelper = false;
    }

    // Preview
    if (!showPreview) {
        settingsSatisfied = true;
    } else {
        defLabel = wellLabels[0];
        for (i = 0; i < wellLabels.length; i++) {
            if (wellLabels[i] == previewLabel) defLabel = previewLabel;
        }
        Dialog.create("Choose preview well");
        Dialog.addMessage("Tip: preview a bright well first, then check a dim well and a negative control.");
        Dialog.addChoice("Well to preview:", wellLabels, defLabel);
        Dialog.show();
        previewLabel = Dialog.getChoice();
        pIdx = findIndex(wellLabels, previewLabel);

        previewDone = false;
        while (!previewDone) {
            res = runPreview(fitcPaths[pIdx], previewLabel, true);
            if (res == 1) {
                previewDone = true;
                accepted = true;
                checkMore = getBoolean("Segmentation accepted for " + previewLabel + ".\n\nTest the same settings on another well\n(e.g. a dim well or a negative control)?");
                while (checkMore) {
                    Dialog.create("Choose another well");
                    Dialog.addChoice("Well to preview:", wellLabels, wellLabels[0]);
                    Dialog.show();
                    otherLabel = Dialog.getChoice();
                    r2 = runPreview(fitcPaths[findIndex(wellLabels, otherLabel)], otherLabel, false);
                    if (r2 != 1) {
                        accepted = false;
                        checkMore = false;
                    } else {
                        checkMore = getBoolean("Test yet another well?");
                    }
                }
                settingsSatisfied = accepted;
            } else if (res == 0) {
                previewDone = true;
                settingsSatisfied = false;
            }
            // res == 2: retry the manual threshold on the same well
        }
    }
    while (nImages > 0) { selectImage(nImages); close(); }
}

// ============================================================
// STEP 4: Choose result columns and image outputs
// ============================================================
Dialog.create("Choose Data Output");
Dialog.addCheckbox("Area (always measured)", true);
Dialog.addCheckbox("Mean Intensity (Avg + Median per well)", true);
Dialog.addCheckbox("Integrated Density (always measured)", true);
Dialog.addCheckbox("Perimeter", false);
Dialog.addCheckbox("Circularity", true);
Dialog.addMessage("--- Image Outputs ---");
Dialog.addCheckbox("Save QC Overlays (recommended)", true);
Dialog.addCheckbox("Create Thumbnail Montage (Originals)", true);
Dialog.addCheckbox("Create Thumbnail Montage (QC Overlays)", true);
Dialog.addMessage("QC display range: use the SAME range for all wells so brightness can be compared by eye.");
Dialog.addNumber("QC display min:", 0);
Dialog.addNumber("QC display max (0 = automatic contrast per image):", 0);
Dialog.show();

doArea        = Dialog.getCheckbox();
doMean        = Dialog.getCheckbox();
doIntDen      = Dialog.getCheckbox();
doPeri        = Dialog.getCheckbox();
doCirc        = Dialog.getCheckbox();
doQC          = Dialog.getCheckbox();
doOrigMontage = Dialog.getCheckbox();
doQCMontage   = Dialog.getCheckbox();
qcMin         = Dialog.getNumber();
qcMax         = Dialog.getNumber();

if (doQCMontage && !doQC) {
    doQC = true;
}

// Area, Mean and Integrated Density are always measured (needed for corrections)
measureString = "area mean integrated ";
if (doPeri) measureString += "perimeter ";
if (doCirc) measureString += "shape ";
run("Set Measurements...", measureString + " display redirect=None decimal=3");

// ============================================================
// Save analysis settings (reproducibility)
// ============================================================
open(fitcPaths[0]);
getPixelSize(pxUnit, pxW, pxH);
imgBits = bitDepth();
close();

getDateAndTime(yr, mo, dow, dom, hr, mi, sc, ms);
stamp = "" + yr + "-" + IJ.pad(mo + 1, 2) + "-" + IJ.pad(dom, 2) + " " + IJ.pad(hr, 2) + ":" + IJ.pad(mi, 2);
if (fixedThr > 0) {
    thrText = "FIXED, lower threshold = " + fixedThr + " (on background-subtracted, filtered image)";
} else {
    thrText = "Algorithm: " + threshMethod + " (threshold differs per well, see Threshold_Used column)";
}
sText = "PlateAnalyzer v11.0 - analysis settings\n";
sText += "Date: " + stamp + "\n";
sText += "Input folder: " + inputDir + "\n";
sText += "FITC suffix: " + fitcSuffix + "   Wells/images: " + wellLabels.length + "\n";
sText += "Image bit depth: " + imgBits + "   Pixel size: " + pxW + " x " + pxH + " " + pxUnit + "\n";
sText += "(Total_Cell_Area and Corr_* area values are in " + pxUnit + "^2 if the image is calibrated, otherwise px^2)\n";
sText += "Threshold: " + thrText + "\n";
sText += "Background subtraction radius (detection only): " + bgRadius + "\n";
sText += "Median filter radius (detection only): " + medianRadius + "\n";
sText += "Particle options: " + particleOptions + "\n";
sText += "Cell preset: " + cellPreset + "\n";
sText += "Measurements are made on the RAW image.\n";
sText += "Background subtracted from measurements (raw units): " + bgValue + "\n";
sText += "QC display range: " + qcMin + " - " + qcMax + " (max 0 = automatic)\n";
File.saveString(sText, outputDir + "Analysis_Settings.txt");

// ============================================================
// STEP 5: Analysis loop
// ============================================================
setBatchMode(true);
nWells = wellLabels.length;
summaryCount = newArray(nWells);
summaryTotalArea = newArray(nWells);
summaryMeanInt = newArray(nWells);
summaryMedianInt = newArray(nWells);
summaryTotalIntDen = newArray(nWells);
summaryNormCellIntDen = newArray(nWells);   // Total IntDen / Count
summaryNormAreaIntDen = newArray(nWells);   // Total IntDen / Area
summaryThr = newArray(nWells);
summaryImgMax = newArray(nWells);

detailedFolder = outputDir + "Detailed_Results/";
if (!File.exists(detailedFolder)) File.makeDirectory(detailedFolder);

qcFolder = outputDir + "QC_Images/";
if (doQC && !File.exists(qcFolder)) File.makeDirectory(qcFolder);

for (w = 0; w < nWells; w++) {
    showProgress(w, nWells);
    open(fitcPaths[w]);
    rawID = getImageID();
    getStatistics(imgArea, imgMean, imgMin, imgMax);
    summaryImgMax[w] = imgMax;

    // Detection on a filtered COPY; the raw image is left untouched
    usedThr = segment(rawID);
    summaryThr[w] = usedThr;

    nCells = roiManager("count");
    summaryCount[w] = nCells;

    selectImage(rawID);

    if (nCells > 0) {
        run("Clear Results");
        roiManager("Measure");

        cellMeans = newArray(nCells);
        sumArea = 0;
        sumID = 0;
        sumM = 0;

        for (r = 0; r < nCells; r++) {
            a   = getResult("Area", r);
            m   = getResult("Mean", r);
            idn = getResult("IntDen", r);
            cm  = m - bgValue;
            cid = idn - bgValue * a;
            setResult("Corr_Mean", r, cm);
            setResult("Corr_IntDen", r, cid);
            cellMeans[r] = cm;
            sumArea += a;
            sumID   += cid;
            sumM    += cm;
        }
        updateResults();
        saveAs("Results", detailedFolder + wellLabels[w] + "_details.csv");

        summaryTotalArea[w]      = sumArea;
        summaryTotalIntDen[w]    = sumID;
        summaryNormCellIntDen[w] = sumID / nCells;
        if (sumArea > 0) {
            summaryNormAreaIntDen[w] = sumID / sumArea;
        } else {
            summaryNormAreaIntDen[w] = 0;
        }
        summaryMeanInt[w] = sumM / nCells;

        Array.sort(cellMeans);
        mid = floor(nCells / 2);
        if (nCells % 2 == 1) {
            summaryMedianInt[w] = cellMeans[mid];
        } else {
            summaryMedianInt[w] = (cellMeans[mid - 1] + cellMeans[mid]) / 2;
        }
    } else {
        // Empty well: no FITC-positive cells found
        summaryTotalArea[w]      = 0;
        summaryMeanInt[w]        = 0;
        summaryMedianInt[w]      = 0;
        summaryTotalIntDen[w]    = 0;
        summaryNormCellIntDen[w] = 0;
        summaryNormAreaIntDen[w] = 0;
    }

    // QC image for EVERY well (keeps the QC montage aligned with the plate layout)
    if (doQC) {
        selectImage(rawID);
        if (qcMax > 0) {
            setMinAndMax(qcMin, qcMax);
        } else {
            run("Enhance Contrast", "saturated=0.35");
        }
        if (nCells > 0) {
            roiManager("Show All without labels");
        } else {
            run("Select None");
        }
        run("Flatten");
        saveAs("PNG", qcFolder + wellLabels[w] + "_QC.png");
        close();
    }

    roiManager("reset");
    while (nImages > 0) { selectImage(nImages); close(); }
}
setBatchMode(false);

// ============================================================
// STEP 6: Save summary
// ============================================================
run("Clear Results");
for (i = 0; i < nWells; i++) {
    setResult("Label", i, wellLabels[i]);
    setResult("Total_Count", i, summaryCount[i]);
    setResult("Total_Cell_Area", i, summaryTotalArea[i]);
    if (doMean) setResult("Avg_Mean_Intensity", i, summaryMeanInt[i]);
    setResult("Total_Integrated_Density", i, summaryTotalIntDen[i]);
    setResult("Avg_IntDen_Per_Cell", i, summaryNormCellIntDen[i]);
    setResult("IntDen_Per_Area", i, summaryNormAreaIntDen[i]);
    if (doMean) setResult("Median_Cell_Mean_Intensity", i, summaryMedianInt[i]);
    setResult("Threshold_Used", i, summaryThr[i]);
    setResult("Raw_Image_Max", i, summaryImgMax[i]);
}
updateResults();
saveAs("Results", outputDir + "A_Summary_Table.csv");

// ============================================================
// STEP 7: Montages
// ============================================================
if (doOrigMontage || doQCMontage) {
    showStatus("Generating Thumbnail Montages...");

    if (doOrigMontage) {
        buildMontage(fitcPaths, wellLabels, outputDir + "Montage_Originals.jpg", "Originals");
    }

    if (doQCMontage) {
        qcPaths = newArray(nWells);
        for (i = 0; i < nWells; i++) {
            qcPaths[i] = qcFolder + wellLabels[i] + "_QC.png";
        }
        buildMontage(qcPaths, wellLabels, outputDir + "Montage_QC_Overlays.jpg", "QC_Overlays");
    }
}

showMessage("Success", "Analysis complete!\nProcessed " + nWells + " wells.\n\nSettings saved in Analysis_Settings.txt");

// ============================================================
// FUNCTIONS
// ============================================================

// Returns the index of value in arr (0 if not found)
function findIndex(arr, value) {
    for (k = 0; k < arr.length; k++) {
        if (arr[k] == value) return k;
    }
    return 0;
}

// Sets the threshold on the active image according to the settings.
// Returns the lower threshold that was used.
function setSegThreshold() {
    if (fixedThr > 0) {
        topVal = 255;
        if (bitDepth() == 16) topVal = 65535;
        if (bitDepth() == 32) topVal = 1e30;
        setThreshold(fixedThr, topVal);
        return fixedThr;
    }
    if (threshMethod == "Manual") {
        setThreshold(userLower, userUpper);
        return userLower;
    }
    setAutoThreshold(threshMethod + " dark");
    getThreshold(lo, hi);
    return lo;
}

// Detects FITC-positive cells on a filtered copy of the image with ID srcID.
// The ROIs are left in the ROI Manager; returns the lower threshold used.
function segment(srcID) {
    selectImage(srcID);
    run("Duplicate...", "title=seg");
    if (bgRadius > 0) run("Subtract Background...", "rolling=" + bgRadius);
    if (medianRadius > 0) run("Median...", "radius=" + medianRadius);
    lower = setSegThreshold();
    run("Convert to Mask");
    run("Watershed");
    roiManager("reset");
    run("Analyze Particles...", particleOptions);
    close("seg");
    return lower;
}

// Shows the segmentation for one well.
// Returns 1 = satisfied, 0 = go back to settings, 2 = retry manual threshold.
function runPreview(path, label, askManual) {
    open(path);
    rawID = getImageID();

    if (threshMethod == "Manual" && fixedThr == 0 && askManual) {
        run("Duplicate...", "title=Manual_Thr");
        if (bgRadius > 0) run("Subtract Background...", "rolling=" + bgRadius);
        if (medianRadius > 0) run("Median...", "radius=" + medianRadius);
        run("Enhance Contrast", "saturated=0.35");
        run("Threshold...");
        waitForUser("Manual threshold", "Set the LOWER threshold with the sliders (do NOT click Apply), then press OK.");
        getThreshold(userLower, userUpper);
        if (userLower < 0) exit("No threshold was set.");
        close("Manual_Thr");
        if (isOpen("Threshold")) {
            selectWindow("Threshold");
            run("Close");
        }
    }

    lower = segment(rawID);
    n = roiManager("count");

    selectImage(rawID);
    run("Duplicate...", "title=Validation_Result");
    run("Enhance Contrast", "saturated=0.35");
    roiManager("Show All with labels");

    ok = getBoolean("Well: " + label + "\nThreshold used: " + d2s(lower, 2) + "\nFITC-positive cells detected: " + n + "\n\nAre you satisfied with this segmentation?");

    while (nImages > 0) { selectImage(nImages); close(); }
    roiManager("reset");

    if (ok) return 1;
    if (threshMethod == "Manual" && fixedThr == 0 && askManual) {
        adjust = getBoolean("Adjust all settings from the beginning?\n(No = retry the manual threshold)");
        if (adjust) return 0;
        return 2;
    }
    return 0;
}

// Suggests a fixed threshold and a background value from a negative control well.
// Sets the global variables fixedThr and bgValue if the user accepts.
function controlHelper(path, kSD) {
    open(path);
    getStatistics(area1, rawMean, rawMin, rawMax, rawSD);
    run("Duplicate...", "title=ctrl_filtered");
    if (bgRadius > 0) run("Subtract Background...", "rolling=" + bgRadius);
    if (medianRadius > 0) run("Median...", "radius=" + medianRadius);
    getStatistics(area2, fMean, fMin, fMax, fSD);
    while (nImages > 0) { selectImage(nImages); close(); }

    suggested = Math.max(1, Math.round(fMean + kSD * fSD));

    msg = "Negative control statistics\n\n";
    msg += "Raw image:      mean " + d2s(rawMean, 2) + ",  SD " + d2s(rawSD, 2) + ",  max " + rawMax + "\n";
    msg += "Filtered image: mean " + d2s(fMean, 2) + ",  SD " + d2s(fSD, 2) + ",  max " + fMax + "\n\n";
    msg += "Suggested threshold (mean + " + kSD + " x SD of the filtered image): " + suggested + "\n\n";
    msg += "This is a starting point. Verify in the preview that negative controls give ~0 cells\nand that a positive control still gives the expected cells.";

    useThr = getBoolean(msg + "\n\nUse " + suggested + " as the fixed threshold for the whole plate?");
    if (useThr) fixedThr = suggested;

    useBg = getBoolean("Subtract the negative control's RAW mean (" + d2s(rawMean, 2) + ") as background from all intensity measurements?\n(No = measure raw values, background 0)");
    if (useBg) bgValue = rawMean;
}

function buildMontage(pathArray, labelArray, savePath, titleName) {
    setBatchMode(true);
    scaleFactor = 0.20;

    for (m = 0; m < pathArray.length; m++) {
        if (File.exists(pathArray[m])) {
            open(pathArray[m]);
            tempID = getImageID();

            run("Scale...", "x=" + scaleFactor + " y=" + scaleFactor + " interpolation=Bilinear average create");
            rename(labelArray[m]);

            selectImage(tempID);
            close();
        }
    }

    run("Images to Stack", "name=["+titleName+"] use");
    n = nSlices;

    cols = Math.ceil(sqrt(n));
    rows = Math.ceil(n / cols);

    // Automatically match standard microplate geometries
    if (n == 96) { cols = 12; rows = 8; }
    else if (n == 384) { cols = 24; rows = 16; }
    else if (n == 24) { cols = 6; rows = 4; }
    else if (n == 12) { cols = 4; rows = 3; }
    else if (n == 6) { cols = 3; rows = 2; }

    run("Make Montage...", "columns=" + cols + " rows=" + rows + " scale=1 border=2 font=14 label");

    saveAs("JPEG", savePath);
    close();
    close(titleName);
    setBatchMode(false);
}
