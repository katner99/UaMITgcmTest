%%%%%%%%%%%
%% TO DO %%
%%%%%%%%%%%
%% -> code appropriate filenames and directories for 
%   + melt output and tracer grid from MITgcm
%   + calendar file
%   + file with user variables
%% -> Write code for reading user variables from file
%% -> Which netcdf output do we want to generate?

function callUa(UserVar,varargin)

if nargin==0
    UserVar=[];
end

%%%%%%%%%%%%%%%%%%%%%%%%
%% collect user input %%
%%%%%%%%%%%%%%%%%%%%%%%%
% read from user input file (TO DO):
UserVar.UaMITgcm.Experiment = 'MISOMIP_1r';

UserVar.UaMITgcm.UaOutputDirectory = './ResultsFiles';
UserVar.UaMITgcm.UaOutputFormat = 'matlab'; % options are 'matlab' or 'netcdf'

UserVar.UaMITgcm.MITgcmOutputDirectory = '.';

%%%%%%%%%%%%%%%%%%%%%%%%%%
%% collect MITgcm input %%
%%%%%%%%%%%%%%%%%%%%%%%%%%

% read calendar file
CAL = textread([UserVar.UaMITgcm.MITgcmOutputDirectory,'/sample_calendar_monthly']);

% save start year and start month in string format
Start = num2str(CAL(1));
UserVar.UaMITgcm.StartYear = Start(1:4);
UserVar.UaMITgcm.StartMonth = Start(5:6);

%convert physical run time to years and save in double format 
UserVar.UaMITgcm.runTime = CAL(2)/365.25; % in years

% generate array of output times for Ua, converted to years
for ii=3:length(CAL)
    OutputInterval(ii-2) = CAL(ii);
end

if OutputInterval(1)==-1
    UserVar.UaMITgcm.UaOutputTimes = [1:UserVar.UaMITgcm.runTime*365.25]/365.25;
elseif OutputInterval(1)==CAL(2)
    UserVar.UaMITgcm.UaOutputTimes = [OutputInterval(1) 2*OutputInterval(1)]/365.25;
else
    UserVar.UaMITgcm.UaOutputTimes = cumsum(OutputInterval)/365.25;
end

% based on the OutputTimes we set the ATStimeStepTarget to be the minimum
% gap between successive output times. This should prevent Ua from
% 'overstepping'. 
UserVar.UaMITgcm.ATStimeStepTarget = min(UserVar.UaMITgcm.UaOutputTimes(2:end)-UserVar.UaMITgcm.UaOutputTimes(1:end-1));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read MITgcm melt rates %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% needs to be adjusted to read the correct input file
MeltFile = [UserVar.UaMITgcm.MITgcmOutputDirectory,'/MITout_2D.nc'];
Melt = double(ncread(MeltFile,'SHIfwFlx')/1000*365*24*60*60);
Melt = squeeze(Melt(:,:,end));
UserVar.UaMITgcm.MITgcmMelt = Melt(:);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read MITgcm grid and check if it’s lat/lon or Cartesian %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% read tracer gridpoints
lon=rdmds('XC');
lat=rdmds('YC');

% check if grid is lat/lon and convert to cartesian if required
if all(lon(:)>=-180) && all(lon(:)<=180) && all(lat(:)>=-90) && all(lat(:)<=90)
    [x,y] = ll2psxy(lat,lon,-71,0);
else
    x = lon;    y = lat;
end

UserVar.UaMITgcm.MITgcmGridX = x;
UserVar.UaMITgcm.MITgcmGridY = y;

%%%%%%%%%%%%
%% run Ua %%
%%%%%%%%%%%%
setenv('UaHomeDirectory','./')
UaHomeDirectory=getenv('UaHomeDirectory'); addpath(genpath(UaHomeDirectory))
Ua2D(UserVar,varargin{:})

end
