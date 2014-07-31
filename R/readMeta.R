#' Read landsat MTL metadata files
#' 
#' Besides reading metadata, readMeta deals with legacy versions of Landsat metadata files and where possible adds missing information (radiometric gain and offset, earth-sun distance).
#' 
#' @param file path to Landsat MTL file (...MTL.txt)
#' @param unifiedMetadata logical. If \code{TRUE} some relevant etadata of Landsat 5:8 are homogenized into a standard format and appended to the original metadata.
#' @return Returns a list containing the Metadata of the MTL file, structured by the original grouping.
#' 
#' @import landsat
#' @export 
#' 
#' 
#' 
readMeta <- function(file, unifiedMetadata = TRUE){
	if(!grepl("MTL", file)) warning("The Landsat metadata file you have specified looks unusual. Typically the filename contains the string 'MTL'. Are you sure you specified the right file? \n I'll try to read it but check the results!")
	
	## Read mtl file
	meta <- read.delim(file, sep = "=", head = FALSE, stringsAsFactors = FALSE, strip.white = TRUE, skip = 1, skipNul = TRUE)
	meta <- meta[-(nrow(meta)-c(1,0)),]
	
	## Retrieve groups
	l <- meta[grep("GROUP",meta[,1]),]
	
	## Assemble metadata list
	meta <- lapply(unique(l[,2]), FUN = function(x){
				w <- which(meta[,2] == x)
				m <- meta[(w[1]+1):(w[2]-1),]
				rownames(m) <- m[,1]
				m <- m[ , 2, drop = FALSE]
				colnames(m) <- "VALUE"
				return(m)
			})
	
	names(meta) <- unique(l[,2])
	
	## Legacy MTL? 
	legacy <- "PROCESSING_SOFTWARE" %in% rownames(meta$PRODUCT_METADATA)
	if(legacy) message("This scene was processed before August 29, 2012. Using MTL legacy format. Some minor infos such as SCENE_ID will be missing")
	
	if(unifiedMetadata){
		
		meta[["UNIFIED_METADATA"]] <- list(
				SPACECRAFT_ID 		= {SAT <- paste0("LANDSAT", getNumeric(meta$PRODUCT_METADATA["SPACECRAFT_ID",]))},
				SENSOR_ID 			= meta$PRODUCT_METADATA["SENSOR_ID",]	,			
				SCENE_ID 			= meta$METADATA_FILE_INFO["LANDSAT_SCENE_ID",],  ## could assemble name for legacy files: http://landsat.usgs.gov/naming_conventions_scene_identifiers.php
				DATA_TYPE			= if(!legacy) meta$PRODUCT_METADATA["DATA_TYPE",] else meta$PRODUCT_METADATA["PRODUCT_TYPE",],
				ACQUISITION_DATE	= {date <- if(!legacy) meta$PRODUCT_METADATA["DATE_ACQUIRED",] else meta$PRODUCT_METADATA["ACQUISITION_DATE",]},
				PROCESSING_DATE		= if(!legacy) meta$METADATA_FILE_INFO["FILE_DATE",] else meta$METADATA_FILE_INFO["PRODUCT_CREATION_TIME",], 
				PATH				= as.numeric(meta$PRODUCT_METADATA["WRS_PATH",]),
				ROW					= if(!legacy) as.numeric(meta$PRODUCT_METADATA["WRS_ROW",]) else as.numeric(meta$PRODUCT_METADATA["STARTING_ROW",]),
				
				FILES				= {files <- row.names(meta[["PRODUCT_METADATA"]])[grep("^.*FILE_NAME", row.names(meta$PRODUCT_METADATA))]
					files <- files[grep("^.*BAND",files)]
					files <- meta[["PRODUCT_METADATA"]][files,]	},
				
				BANDS 				= {junk <- unique(sapply(str_split(files, "_B"), "[" ,1 ))
					str_replace(str_replace(files, paste0(junk,"_"), ""), {if(SAT=="LANDSAT5") "0.TIF" else ".TIF"}, "")
				},
				
				## INSOLATION
				SUN_AZIMUTH			= if(!legacy) as.numeric(meta$IMAGE_ATTRIBUTES["SUN_AZIMUTH",]) else as.numeric(meta$PRODUCT_PARAMETERS["SUN_AZIMUTH",]),
				SUN_ELEVATION		= if(!legacy) as.numeric(meta$IMAGE_ATTRIBUTES["SUN_ELEVATION",]) else as.numeric(meta$PRODUCT_PARAMETERS["SUN_ELEVATION",]),
				EARTH_SUN_DISTANCE  = {es <- meta$IMAGE_ATTRIBUTES["EARTH_SUN_DISTANCE",]
					if(is.null(es) || is.na(es)) es <- ESdist(date)
					as.numeric(es)}
		)
		
		## RADIOMETRIC CORRECTION/RESCALING PARAMETERS
		RADCOR <-  if(!legacy) { list(		
							RAD_OFFSET				= {
								r <- meta$RADIOMETRIC_RESCALING
								r[,1]		<- as.numeric(r[,1])
								bandnames	<- str_c("B", str_replace(rownames(r), "^.*_BAND_", ""))
								go			<- grep("RADIANCE_ADD*", rownames(r))
								ro 			<- r[go,]
								names(ro)	<- bandnames[go]
								ro},
							RAD_GAIN				= {go			<- grep("RADIANCE_MULT*", rownames(r))
								ro 			<- r[go,]
								names(ro)	<- bandnames[go]
								ro},
							REF_OFFSET				= {	go			<- grep("REFLECTANCE_ADD*", rownames(r))
								ro 			<- r[go,]
								names(ro)	<- bandnames[go]
								ro},
							REF_GAIN				= {go			<- grep("REFLECTANCE_MULT*", rownames(r))
								ro 			<- r[go,]
								names(ro)	<- bandnames[go]
								ro})
				} else {
					
					bandnames <- paste0("B", getNumeric(rownames(meta$MIN_MAX_RADIANCE)))
					bandnames <- bandnames[seq(1, length(bandnames), 2)]
					
					L <- diff(as.numeric(meta$MIN_MAX_RADIANCE[,1]))
					L <- L[seq(1, length(L), 2)] 
					
					Q <- diff(as.numeric(meta$MIN_MAX_PIXEL_VALUE[,1]))  
					Q <- Q[seq(1, length(Q), 2)]
					
					G_rescale <- L/Q
					B_rescale <- as.numeric(meta$MIN_MAX_RADIANCE[,1])[seq(2,nrow(meta$MIN_MAX_RADIANCE),2)] - (G_rescale) * 1
					
					RAD_OFFSET 	<- -1 * B_rescale / G_rescale  
					RAD_GAIN	 <- 1 / G_rescale
					
					names(RAD_OFFSET) <- names(RAD_GAIN) <- bandnames
					
					list(RAD_OFFSET = RAD_OFFSET, RAD_GAIN = RAD_GAIN)
					
				}
		
		meta[["UNIFIED_METADATA"]] <- c(meta[["UNIFIED_METADATA"]], RADCOR)
	}
	
	return(meta)
}


#' Extract numbers from strings
#' 
#' @param x string or vector of strings
#' @param returnNumeric logical. should results be formatted \code{as.numeric}? If so, "05" will be converted to 5. Set returnNumeric to \code{FALSE} to keep preceeding zeros.
#' @note decimal numbers will be returned as two separate numbers
#' 
getNumeric <- function(x, returnNumeric = TRUE) {
	sapply(x, function(xi){
				d <- strsplit(xi, "[^[:digit:]]")[[1]]
				d <- if(returnNumeric) as.numeric(d[d!=""]) else d[d!=""]
				d
			})
}




#' Import separate Landsat files into single stack
#' 
#' Reads Landsat MTL metadata file and loads single Landsat Tiffs into a rasterStack.
#' Be aware that by default stackLS() does NOT import panchromatic bands nor thermal bands with resolutions != 30m.
#' 
#' @param file character. Path to Landsat MTL metadata file.
#' @param allResolutions logical. if \code{TRUE} a list will be returned with length = unique spatial resolutions.
#' @param resampleTIR logical. As of  the USGS resamples TIR bands to 30m. Use this option if you use data processed prior to February 25, 2010 which has not been resampled.
#' @param resamplingMethod character. Method to use for TUR resampling ('ngb' or 'bilinear'). Defaults to 'ngb' (nearest neighbor).
#' @return Either a list of rasterStacks comprising all resolutions or only one rasterStack comprising only 30m resolution imagery
#' @note 
#' Be aware that by default stackLS() does NOT import panchromatic bands nor thermal bands with resolutions != 30m. Use the allResolutions argument to import all layers.
#' 
#' The USGS uses cubic convolution to resample TIR bands to 30m resolution. In the opinion of the author this may not be the best choice for supersampling. 
#' Therefore the default method in this implementation is nearest neighbor. Keep this in mind if you plan to compare TIR bands created by differing resampling routines.
#' Typically, however, you will already have the USGS 30m TIR products, so no need to worry...
#' @export
stackLS <- function(file, allResolutions = FALSE,  resampleTIR = FALSE, resamplingMethod = "ngb"){
	
	## Read metadata and extract layer file names
	meta  <- readMeta(file)
	files <- meta$UNIFIED_METADATA$FILES
	
	## Load layers
	path  <- if(basename(file) != file)  str_replace(file, basename(file), "") else NULL
		
	## Import rasters
	rl <- lapply(paste0(path, files), raster)
	resL <- lapply(lapply(rl, res),"[", 1)
	
	if(any(resL > 30)) {
		message("Your Landsat data includes TIR band(s) which were not resampled to 30m.
						\nYou can set resampleTIR = TRUE to resample TIR bands to 30m if you want a single stack")
		
		## Resample TIR to 30m
		if(resampleTIR){
			for(i in which(resL > 30))
				rl[[i]] <- resample(rl[[i]], rl[[which(resL == 30)[1]]], method = resamplingMethod)		
		}
	}
	## Stack
	returnRes <- if(allResolutions) unlist(unique(resL)) else 30
	LS 	<- lapply(returnRes, function(x){
				s <- stack(rl[resL == x])
				names(s) <- meta$UNIFIED_METADATA$BANDS[resL == x]
				s
			})
	
	if(!allResolutions) LS <- LS[[1]]
		
	return(LS)
}