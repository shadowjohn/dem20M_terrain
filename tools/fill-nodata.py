import argparse
import os
import sys

from osgeo import gdal


def parse_args():
    parser = argparse.ArgumentParser(description="Fill small NoData holes in a single-band raster.")
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--max-distance", type=float, default=5.0)
    parser.add_argument("--smoothing-iterations", type=int, default=0)
    parser.add_argument("--nodata", type=float, default=-32768.0)
    return parser.parse_args()


def main():
    args = parse_args()
    gdal.UseExceptions()

    source = gdal.Open(args.source, gdal.GA_ReadOnly)
    if source is None:
        raise RuntimeError("Cannot open source raster: {0}".format(args.source))

    if source.RasterCount < 1:
        raise RuntimeError("Source raster has no bands: {0}".format(args.source))

    target_dir = os.path.dirname(os.path.abspath(args.target))
    if target_dir and not os.path.isdir(target_dir):
        os.makedirs(target_dir)

    if os.path.exists(args.target):
        os.remove(args.target)

    driver = gdal.GetDriverByName("GTiff")
    target = driver.CreateCopy(
        args.target,
        source,
        strict=0,
        options=["TILED=YES", "COMPRESS=LZW", "BIGTIFF=IF_SAFER"],
    )
    if target is None:
        raise RuntimeError("Cannot create target raster: {0}".format(args.target))

    band = target.GetRasterBand(1)
    band.SetNoDataValue(args.nodata)

    # 只補小範圍 NoData，大片無資料區仍維持 NoData，避免產生不可信地形。
    result = gdal.FillNodata(
        targetBand=band,
        maskBand=band.GetMaskBand(),
        maxSearchDist=args.max_distance,
        smoothingIterations=args.smoothing_iterations,
    )
    if result != 0:
        raise RuntimeError("gdal.FillNodata failed with code {0}".format(result))

    band.SetNoDataValue(args.nodata)
    band.FlushCache()
    target.FlushCache()
    target = None
    source = None
    return 0


if __name__ == "__main__":
    sys.exit(main())
