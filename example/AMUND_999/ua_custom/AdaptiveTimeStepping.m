function [RunInfo,dtOut,dtRatio]=AdaptiveTimeStepping(UserVar,RunInfo,CtrlVar,MUA,F)
    
    %% dtOut=AdaptiveTimeStepping(time,dtIn,nlInfo,CtrlVar)
    %  modifies time step size
    %
    % Decision about increasing the time step size is based on the number of non-linear interations over the last few time steps.
    %
    % The main idea is to limit the number of non-linear iteration so that the NR is within the quadradic regime
    % Experience has shown that a target number of iterations (CtrlVar.ATSTargetIterations) within 3 to 5 is good for this purpose
    %
    % Time step is increased if r<1 where
    %
    %     r=N/M
    %
    %   where
    %   N is the max number of non-linear iteration over last n time steps
    %   M is the target number of iterations
    %
    %   here
    %     M=CtrlVar.ATSTargetIterations
    %   and
    %     n=CtrlVar.ATSintervalUp
    %
    %   (N does not need to be specifed.)
    %
    %  Currently the time step is only decreased if either:
    %        a) the number of non-linear iterations in last time step was larger than 25
    %        b) number of iterations over last n times steps were all larger than 10
    %  where n=CtrlVar.ATSintervalDown
    %
    % There are some further modifications possible:
    %  -time step is adjusted so that time interval for making transient plots (CtrlVar.TransientPlotDt) is not skipped over
    %  -time step is not increased further than the target time step CtrlVar.ATSdtMax
    %  -time step is adjusted so that total simulation time does not exceed CtrlVar.TotalTime
    %
    %
    %
    
    narginchk(5,5)
    
    persistent dtNotUserAdjusted dtOutLast dtModifiedOutside
    
    RunInfo.Forward.AdaptiveTimeSteppingTimeStepModifiedForOutputs=0 ;
    
    time=CtrlVar.time;
    dtIn=CtrlVar.dt ;
    
    
    if ~CtrlVar.Implicituvh
        % adaptive time-stepping only implemented for a transient uvh setp
        dtOut=dtIn; 
        dtRatio=dtOut/dtIn;
        return
    end
    

    
    if isempty(dtModifiedOutside)
        dtModifiedOutside=false;
    end
    
 
    
    
    % potentially dt was previously adjusted for plotting/saving purposes
    % if so then dtNotUserAdjusted is the previous unmodified time step
    % and I do want to revert to that time step. I do so only
    % however if dt has not been changed outside of function
    if ~isempty(dtOutLast)
        if dtIn==dtOutLast  % dt not modified outside of function
            if ~isempty(dtNotUserAdjusted)
                dtIn=dtNotUserAdjusted ;
            end
        else
 
            RunInfo.Forward.AdaptiveTimeSteppingResetCounter=0;
            dtModifiedOutside=true;
        end
    end
    
    dtOut=dtIn ;
    
    
    
    % I first check if the previous forward calculation did not converge. If it did
    % not converge I reduced the time step and reset all info about previous
    % interations to reset the adaptive-time stepping approuch
    
    
    RunInfo.Forward.AdaptiveTimeSteppingResetCounter=RunInfo.Forward.AdaptiveTimeSteppingResetCounter+1; 
    
    
    if ~RunInfo.Forward.Converged || dtModifiedOutside
        
        
        dtModifiedOutside=false ;
        
        if ~RunInfo.Forward.Converged
            dtOut=dtIn/CtrlVar.ATStimeStepFactorDownNOuvhConvergence;
            fprintf(CtrlVar.fidlog,' ---------------- Adaptive Time Stepping: time step decreased from %-g to %-g due to lack of convergence in last uvh step. \n ',dtIn,dtOut);
        end
        
        
    elseif CtrlVar.AdaptiveTimeStepping && CtrlVar.CurrentRunStepNumber>1

        
        ItVector=RunInfo.Forward.uvhIterations(max(CtrlVar.CurrentRunStepNumber-5,1):CtrlVar.CurrentRunStepNumber-1);
        nItVector=numel(ItVector) ;

        
        % TimeStepUpRatio the ratio between maximum number of non-linear iterations over
        % last CtrlVar.ATSintervalUp iterations, divided by CtrlVar.ATSTargetIterations 
        % It TimeStepUpRatio is smaller than 1, the number of non-linear iterations has
        % consistently been below target and time step should potentially be increased.
        
        if (CtrlVar.CurrentRunStepNumber-1)>=CtrlVar.ATSintervalUp
            TimeStepUpRatio=max(RunInfo.Forward.uvhIterations(max(CtrlVar.CurrentRunStepNumber-1-CtrlVar.ATSintervalUp+1,1):CtrlVar.CurrentRunStepNumber-1))/CtrlVar.ATSTargetIterations ;
        else
            TimeStepUpRatio=NaN ;
        end
        
        if (CtrlVar.CurrentRunStepNumber-1)>=CtrlVar.ATSintervalDown
            TimeStepDownRatio=min(RunInfo.Forward.uvhIterations(max(CtrlVar.CurrentRunStepNumber-1-CtrlVar.ATSintervalDown+1,1):CtrlVar.CurrentRunStepNumber-1))/CtrlVar.ATSTargetIterations ;
        else
            TimeStepDownRatio=NaN;
        end
        
        
        fprintf(CtrlVar.fidlog,' Adaptive Time Stepping:  #Non-Lin Iterations over last %-i time steps: (max|mean|min)=(%-g|%-g|%-g). Target is %-i. \t TimeStepUpRatio=%-g \n ',...
            nItVector,max(ItVector),mean(ItVector),min(ItVector),CtrlVar.ATSTargetIterations,TimeStepUpRatio);
        
        if RunInfo.Forward.uvhIterations(CtrlVar.CurrentRunStepNumber-1)==666  % This is a special forced reduction whenever RunInfo.Forward.uvhIterations has been set to this value
            
            
            dtOut=dtIn/CtrlVar.ATStimeStepFactorDown;
            RunInfo.Forward.AdaptiveTimeSteppingResetCounter=0;
            fprintf(CtrlVar.fidlog,' ---------------- Adaptive Time Stepping: time step decreased from %-g to %-g \n ',dtIn,dtOut);
            
            
        elseif RunInfo.Forward.AdaptiveTimeSteppingResetCounter > 2 && RunInfo.Forward.uvhIterations(CtrlVar.CurrentRunStepNumber-1)>25
            
            % This is also a special case to cover the possibilty that there is a sudden
            % increase in the number of non-linear iterations, or if the initial time step
            % a the start of a run was set too large.
            dtOut=dtIn/CtrlVar.ATStimeStepFactorDown;
            dtOut=max(dtOut,CtrlVar.ATSdtMin) ;
            RunInfo.Forward.AdaptiveTimeSteppingResetCounter=0;
            if dtOut<dtIn
                fprintf(' ---------------- Adaptive Time Stepping: time step decreased from %-g to %-g \n ',dtIn,dtOut);
            end
        else
            
            % This is the more general case.
            
            if RunInfo.Forward.AdaptiveTimeSteppingResetCounter>CtrlVar.ATSintervalDown && ~isnan(TimeStepDownRatio)
                
                % Potentially decrease time step
                
                if all(ItVector(1:CtrlVar.ATSintervalDown) > (CtrlVar.ATSTargetIterations+2) )  ||  ( TimeStepDownRatio > 2 )
                    dtOut=dtIn/CtrlVar.ATStimeStepFactorDown;
                    dtOut=max(dtOut,CtrlVar.ATSdtMin) ;
                    RunInfo.Forward.AdaptiveTimeSteppingResetCounter=0;
                    
                    if dtOut<dtIn
                        fprintf(' ---------------- Adaptive Time Stepping: time step decreased from %-g to %-g \n ',dtIn,dtOut)
                    end
                    
                end
            end
            
            if RunInfo.Forward.AdaptiveTimeSteppingResetCounter>CtrlVar.ATSintervalUp  && ~isnan(TimeStepUpRatio)
                if  TimeStepUpRatio<1
                    
                    % Potentially increase time step 
                    
                    dtOut=min(CtrlVar.ATSdtMax,dtIn*CtrlVar.ATStimeStepFactorUp);
                    RunInfo.Forward.AdaptiveTimeSteppingResetCounter=0;
                    
%                     if  CtrlVar.DefineOutputsDt>0
%                         
%                         Fraction=dtOut/CtrlVar.DefineOutputsDt;
%                         if Fraction>=1  % Make sure dt is not larger than the interval between DefineOutputs
%                             dtOut=CtrlVar.DefineOutputsDt;
%                         elseif Fraction>0.1   % if dt is greater than 10% of DefineOutputs interval, round dt
%                             % so that it is an interger multiple of DefineOutputsDt
%                             fprintf('Adaptive Time Stepping dtout=%f \n ',dtOut);
%                             dtOut=CtrlVar.DefineOutputsDt/RoundNumber(CtrlVar.DefineOutputsDt/dtOut,1);
%                             fprintf('Adaptive Time Stepping dtout=%f \n ',dtOut);
%                         end
%                     end
                    
                    
                    
                    if CtrlVar.ATSdtMax <= dtOut
                        dtOut=CtrlVar.ATSdtMax ;
                        fprintf(CtrlVar.fidlog,' ---------------- Adaptive Time Stepping: time step has reached max allowed automated time step of %-g and is therefore not increased further \n ',CtrlVar.ATSdtMax);
                    else
                        if dtOut>dtIn
                            fprintf(CtrlVar.fidlog,' ---------------- Adaptive Time Stepping: time step increased from %-g to %-g \n ',dtIn,dtOut);
                        end
                    end
                    
                    
                end
            end
        end
    end
    
    if  CtrlVar.EnforceCFL ||  ~CtrlVar.Implicituvh   % If in semi-implicit step, make sure not to violate CFL condition
        
        dtcritical=CalcCFLdt2D(UserVar,RunInfo,CtrlVar,MUA,F) ;
        
        if dtOut>dtcritical
            
            dtOut=dtcritical ;
            
            fprintf('AdaptiveTimeStepping: dt > dt (CFL) and therefore dt reduced to %f \n',dtOut)
            
        end
    end
    
    
    if CtrlVar.ATSTdtRounding && CtrlVar.DefineOutputsDt(CtrlVar.DefineOutputsCounter+1)~=0
        % rounding dt to within 10% of Dt
        dtOut=CtrlVar.DefineOutputsDt(CtrlVar.DefineOutputsCounter+1)/round(CtrlVar.DefineOutputsDt(CtrlVar.DefineOutputsCounter+1)/dtOut,1,'significant') ;
    end
    
    
    
    
    RunInfo.Forward.dtRestart=dtOut ;  % Create a copy of dtOut before final modifications related to plot times and end times.
    % This is the dt to be used in further restart runs
    
    %% dtOut has now been set, but I need to see if the user wants outputs/plots at given time intervals and
    % if I am possibly overstepping one of those intervals.
    %
    dtOutCopy=dtOut;  % keep a copy of dtOut to be able to revert to previous time step
    % after this adjustment
    
    %
    if CtrlVar.DefineOutputsDt(CtrlVar.DefineOutputsCounter+1)>0
        temp=dtOut;
        dtOut=NoOverStepping(CtrlVar,time,dtOutCopy,CtrlVar.DefineOutputsDt(CtrlVar.DefineOutputsCounter+1));
        if abs(temp-dtOut)>100*eps
            fprintf(CtrlVar.fidlog,' Adaptive Time Stepping: dt modified to accommodate user output requirements and set to %-g \n ',dtOut);
            RunInfo.Forward.AdaptiveTimeSteppingTimeStepModifiedForOutputs=1; 
        end
    end
    
    
    
    %% make sure that run time does not exceed total run time as defined by user
    % also check if current time is very close to total time, in which case there
    % is no need to change the time step
    if time+dtOut>CtrlVar.TotalTime && abs(time-CtrlVar.TotalTime)>100*eps
        
        dtOutOld=dtOut;
        dtOut=CtrlVar.TotalTime-time;
        
        if dtOutOld ~= dtOut
            fprintf(CtrlVar.fidlog,' Adaptive Time Stepping: dt modified to %-g to give a correct total run time of %-g \n ',dtOut,CtrlVar.TotalTime);
        end
    end
    
    
    %%
    
    if dtOutCopy~=dtOut
        dtNotUserAdjusted=dtOutCopy;
    else
        dtNotUserAdjusted=[];
    end
    
    dtOutLast=dtOut;
    
    
    dtRatio=dtOut/dtIn;
    
    %%
    if dtOut==0
        save TestSave
        error('dtOut is zero')
    end
    
    
    
    
end



