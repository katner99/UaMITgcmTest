################################################################################
# Functions to exchange data between MITgcm and Ua, and adjust the MITgcm geometry/initial conditions as needed.
################################################################################

import numpy as np
from scipy.io import savemat, loadmat
import os

from coupling_utils import read_last_output, find_open_cells, move_to_dir

from mitgcm_python.utils import convert_ismr
from mitgcm_python.make_domain import do_digging, do_zapping
from mitgcm_python.file_io import read_binary, write_binary
from mitgcm_python.interpolation import discard_and_fill
from mitgcm_python.ics_obcs import calc_load_anomaly
        

# Put MITgcm melt rates in the right format for Ua. No need to interpolate.

# Arguments:
# mit_dir: MITgcm directory containing SHIfwFlx output
# ua_out_file: desired path to .mat file for Ua to read melt rates from.
# grid: Grid object (for the MITgcm segment that just finished)
# options: Options object

def extract_melt_rates (mit_dir, ua_out_file, grid, options):

    # Read the most recent ice shelf melt rate output and convert to m/y,
    # melting is negative as per Ua convention.
    # Make sure it's from the last timestep of the previous simulation.
    ismr = -1*convert_ismr(read_last_output(mit_dir, options.ismr_name, 'SHIfwFlx', timestep=options.last_timestep))

    # Put everything in exactly the format that Ua wants: long 1D arrays with an empty second dimension, and double precision
    lon_points = np.ravel(grid.lon_1d)[:,None].astype('float64')
    lat_points = np.ravel(grid.lat_1d)[:,None].astype('float64')
    ismr_points = np.ravel(ismr)[:,None].astype('float64')

    # Write to Matlab file for Ua, as long 1D arrays
    print 'Writing ' + ua_out_file
    savemat(ua_out_file, {'meltrate':ismr_points, 'x':lon_points, 'y':lat_points})  


# Given the updated ice shelf draft from Ua, adjust the draft and/or bathymetry so that MITgcm is happy. In order to have fully connected adjacent water columns, they must overlap by at least two wet cells.
# There are three ways to do this (set in options.digging):
#    'none': ignore the 2-cell rule and don't dig anything
#    'bathy': dig bathymetry which is too shallow (starting with original, undug bathymetry so that digging is reversible)
#    'draft': dig ice shelf drafts which are too deep
# In all cases, also remove ice shelf drafts which are too thin.
# Ua does not see these changes to the geometry.

# Arguments:
# ua_draft_file: path to .mat ice shelf draft file written by Ua at the end of the last segment
# mit_dir: path to MITgcm directory containing binary files for bathymetry and ice shelf draft
# grid: Grid object
# options: Options object

def adjust_mit_geom (ua_draft_file, mit_dir, grid, options):

    # Read the ice shelf draft and mask from Ua
    # TODO: deal with changing land mask
    f = loadmat(ua_draft_file)
    draft = np.transpose(f['b_forMITgcm'])
    mask = np.transpose(f['mask_forMITgcm'])
    # Mask grounded ice out of ice shelf draft
    draft[mask==0] = 0

    # Read MITgcm bathymetry file
    if options.digging == 'bathy':
        # Read original (pre-digging) bathymetry, so that digging is reversible
        bathyFile_read = options.bathyFileOrig
    else:
        # Read bathymetry from last segment
        bathyFile_read = options.bathyFile    
    bathy = read_binary(mit_dir+bathyFile_read, [grid.nx, grid.ny], 'xy', prec=options.readBinaryPrec)

    if options.digging == 'none':
        print 'Not doing digging as per user request'
    elif options.digging == 'bathy':
        print 'Digging bathymetry which is too shallow'
        bathy = do_digging(bathy, draft, grid.dz, grid.z_edges, hFacMin=options.hFacMin, hFacMinDr=options.hFacMinDr, dig_option='bathy')
    elif options.digging == 'draft':
        print 'Digging ice shelf drafts which are too deep'
        draft = do_digging(bathy, draft, grid.dz, grid.z_edges, hFacMin=options.hFacMin, hFacMinDr=options.hFacMinDr, dig_option='draft')

    print 'Zapping ice shelf drafts which are too thin'
    draft = do_zapping(draft, draft!=0, grid.dz, grid.z_edges, hFacMinDr=options.hFacMinDr)
    
    # Ice shelf draft could change in all three cases
    write_binary(draft, mit_dir+options.draftFile, prec=options.readBinaryPrec)
    if options.digging == 'bathy':
        # Bathymetry can only change in one case
        write_binary(bathy, mit_dir+options.bathyFile, prec=options.readBinaryPrec)


# Read MITgcm's state variables from the end of the last segment, and adjust them to create initial conditions for the next segment.
# Any cells which have opened up since the last segment (due to Ua's simulated ice shelf draft changes + MITgcm's adjustments eg digging) will have temperature and salinity set to the average of their nearest neighbours, and velocity to zero.
# Sea ice (if active) will also set to zero area, thickness, snow depth, and velocity in the event of a retreat of the ice shelf front.
# Also set the new pressure load anomaly.

# Arguments:
# mit_dir: path to MITgcm directory containing binary files for bathymetry, ice shelf draft, initial conditions, and final state
# grid: Grid object
# options: Options object

def set_mit_ics (mit_dir, grid, options):

    # Read the final state of ocean variables
    temp, salt, u, v = read_last_output(mit_dir, options.final_state_name, ['THETA', 'SALT', 'UVEL', 'VVEL'], timestep=options.last_timestep)
    if options.use_seaice:
        # Read the final state of sea ice variables
        aice, hice, hsnow, uice, vice = read_last_output(mit_dir, options.seaice_final_state_name, ['SIarea', 'SIheff', 'SIhsnow', 'SIuice', 'SIvice'], timestep=options.last_timestep)
    
    # Read the new ice shelf draft, and also the bathymetry
    draft = read_binary(mit_dir+options.draftFile, [grid.nx, grid.ny], 'xy', prec=options.readBinaryPrec)
    bathy = read_binary(mit_dir+options.bathyFile, [grid.nx, grid.ny], 'xy', prec=options.readBinaryPrec)

    print 'Selecting newly opened cells'
    # Figure out which cells will be (at least partially) open in the next segment
    open_next = find_open_cells(bathy, draft, grid, options.hFacMin, options.hFacMinDr)
    # Also save this as a mask with 1s and 0s
    mask_new = open_next.astype(int)
    # Now select the open cells which weren't already open in the last segment
    newly_open = open_next*(grid.hfac==0)

    print 'Extrapolating temperature into newly opened cells'
    temp_new = discard_and_fill(temp, [], newly_open, missing_val=0)
    print 'Extrapolating salinity into newly opened cells'
    salt_new = discard_and_fill(salt, [], newly_open, missing_val=0)
    
    # Write the new initial conditions, masked with 0s (important in case maskIniTemp and/or maskIniSalt are off)
    write_binary(temp_new*mask_new, mit_dir+options.ini_temp_file, prec=readBinaryPrec)
    write_binary(salt_new*mask_new, mit_dir+options.ini_salt_file, prec=readBinaryPrec)

    # Write the initial conditions which haven't changed
    # No need to mask them, as velocity and sea ice variables are always masked when they're read in
    write_binary(u, mit_dir+options.ini_u_file, prec=readBinaryPrec)
    write_binary(v, mit_dir+options.ini_v_file, prec=readBinaryPrec)
    if options.use_seaice:
        write_binary(aice, mit_dir+options.ini_area_file, prec=readBinaryPrec)
        write_binary(hice, mit_dir+options.ini_heff_file, prec=readBinaryPrec)
        write_binary(hsnow, mit_dir+options.ini_hsnow_file, prec=readBinaryPrec)
        write_binary(uice, mit_dir+options.ini_uice_file, prec=readBinaryPrec)
        write_binary(vice, mit_dir+options.ini_vice_file, prec=readBinaryPrec)

    print 'Calculating pressure load anomaly'
    calc_load_anomaly(grid, mit_dir+options.pload_file, option=options.pload_option, constant_t=pload_temp, constant_s=pload_salt, ini_temp_file=mit_dir+options.ini_temp_file, ini_salt_file=mit_dir+options.ini_salt_file, eosType=options.eosType, rhoConst=options.rhoConst, Talpha=options.tAlpha, Sbeta=options.sBeta, Tref=options.Tref, Sref=options.Sref, prec=options.readBinaryPrec)


# Convert all the MITgcm binary output files in run/ to NetCDF, using the xmitgcm package.
# Arguments:
# options: Options object
# TODO: check if this breaks with FinalState snapshots. Should we just convert output_names? Or convert output_names and final_state_name/seaice_final_state_name separately?
def convert_mit_output (options):

    # Wrap import statement inside this function, so that xmitgcm isn't required to be installed unless needed
    from xmitgcm import open_mdsdataset

    # Get startDate in the right format for NetCDF
    ref_date = startDate[:4]+'-'+startDate[4:6]+'-'+startDate[6:8]+' 0:0:0'

    # Read all the MDS files in run/
    ds = open_mdsdataset(options.mit_run_dir, delta_t=options.deltaT, ref_date=ref_date)

    # Save to NetCDF file
    ds.to_netcdf(options.mit_run_dir+options.mit_nc_name, unlimited_dims=['time'])


# Gather all output from MITgcm and Ua, moving it to a common subdirectory of options.output_dir.
# Arguments:
# options: Options object
# spinup: boolean indicating we're in the ocean-only spinup phase, so there is no Ua output to deal with
# TODO: Move Ua output into new folder
def gather_output (options, spinup):

    # Make a subdirectory named after the starting date of the simulation segment
    new_dir = options.output_dir + options.last_start_date + '/'
    print 'Creating ' + new_dir
    os.mkdir(new_dir)    

    if options.use_xmitgcm:
        # Move the NetCDF file created by convert_mit_output into the new folder
        # First check it actually exists
        if not os.path.isfile(options.mit_run_dir+options.mit_nc_name):
            print 'Error gathering output'
            print 'xmitgcm conversion was unsuccessful'
            sys.exit()
        move_to_dir(options.mit_nc_name, options.mit_run_dir, new_dir)
            
    # Deal with MITgcm binary output files
    for fname in os.listdir(options.mit_run_dir):
        if fname.startswith('state') and (fname.endswith('.data') or fname.endswith('.meta')):
            if options.use_xmitgcm:
                # Delete binary files which were savely converted to NetCDF
                os.remove(options.mit_run_dir+fname)
            else:
                # Move binary files to output directory
                move_to_dir(fname, options.mit_run_dir, new_dir)

    if not spinup:
        # TODO: Move Ua output into this folder

        # Move coupling files into the subdirectory
        move_to_dir(options.ua_melt_file, options.output_dir, new_dir)
        move_to_dir(options.ua_draft_file, options.output_dir, new_dir
    


    
    

    
